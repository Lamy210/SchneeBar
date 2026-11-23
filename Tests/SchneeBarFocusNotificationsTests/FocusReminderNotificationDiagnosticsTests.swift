import Foundation
import SchneeBarFocusCore
import SchneeBarFocusPersistence
@testable import SchneeBarFocusNotifications
import Testing

private actor FocusDiagnosticsCenterStub: FocusReminderNotificationCenterPort {
    let authorization: FocusReminderNotificationAuthorization
    let pending: [String]
    let delivered: [String]
    private var authorizationReads = 0
    private var pendingReads = 0
    private var deliveredReads = 0
    private var submissions = 0
    private var removals = 0

    init(
        authorization: FocusReminderNotificationAuthorization = .authorized,
        pending: [String] = [],
        delivered: [String] = []
    ) {
        self.authorization = authorization
        self.pending = pending
        self.delivered = delivered
    }

    func authorizationStatus() async -> FocusReminderNotificationAuthorization {
        authorizationReads += 1
        return authorization
    }

    func add(_ request: FocusReminderNotificationRequest) async throws {
        submissions += 1
    }

    func pendingIdentifiers() async -> [String] {
        pendingReads += 1
        return pending
    }

    func deliveredIdentifiers() async -> [String] {
        deliveredReads += 1
        return delivered
    }

    func remove(identifiers: [String]) async {
        removals += 1
    }

    func counts() -> [Int] {
        [authorizationReads, pendingReads, deliveredReads, submissions, removals]
    }
}

private func withDiagnosticsStore(
    _ body: (FocusReminderCollectionStore, URL) async throws -> Void
) async throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(
        at: dir, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700]
    )
    defer { try? FileManager.default.removeItem(at: dir) }
    let file = dir.appendingPathComponent("reminders.json")
    try await body(FocusReminderCollectionStore(fileURL: file), file)
}

private func makeDiagnosticsOutbox(
    store: FocusReminderCollectionStore
) async throws -> FocusReminderOutboxRecord {
    let start = Date(timeIntervalSince1970: 1_700_000_000)
    let due = start.addingTimeInterval(60)
    let calendar = Calendar(identifier: .gregorian)
    let entry = try await store.add(title: "CONFIDENTIAL TITLE", rule: .once(due))
    _ = try await store.apply(id: entry.id, command: .update(.setEnabled(true)), at: start)
    let planned = try await store.apply(
        id: entry.id, command: .update(.replan(calendar)), at: start
    )
    let ticket = try #require(planned.snapshot.entries.first?.state.pending)
    let claimed = try await store.apply(
        id: entry.id, command: .update(.claim(ticketID: ticket.id, calendar: calendar)), at: due
    )
    return try #require(claimed.enqueued)
}

@Test func focusDiagnosticsEmptyStoreHasNoSideEffects() async throws {
    try await withDiagnosticsStore { store, file in
        let port = FocusDiagnosticsCenterStub()
        let gateway = FocusReminderNotificationGateway(center: port)
        let reader = FocusReminderNotificationDiagnosticsReader(store: store, gateway: gateway)
        let summary = try await reader.load()
        #expect(summary.durableOutboxCount == 0)
        #expect(summary.observedOutboxCount == 0)
        #expect(summary.missingSystemEvidenceCount == 0)
        #expect(!summary.requiresManualReview)
        #expect(!FileManager.default.fileExists(atPath: file.path))
        #expect(await port.counts() == [1, 1, 1, 0, 0])
    }
}

@Test func focusDiagnosticsDeduplicatesOwnedEvidenceAndCountsIgnoredIdentifiers() async throws {
    try await withDiagnosticsStore { store, file in
        let record = try await makeDiagnosticsOutbox(store: store)
        let id = FocusReminderNotificationIdentity.identifier(for: record.id)
        let orphan = FocusReminderNotificationIdentity.identifier(for: UUID())
        let port = FocusDiagnosticsCenterStub(
            pending: [id, id, "github-recovery:other"],
            delivered: [id, orphan]
        )
        let reader = FocusReminderNotificationDiagnosticsReader(
            store: store, gateway: FocusReminderNotificationGateway(center: port)
        )
        let before = try Data(contentsOf: file)
        let summary = try await reader.load()
        #expect(summary.authorization == .authorized)
        #expect(summary.evidenceQuality == .nonAtomicSnapshot)
        #expect(summary.observedOutboxCount == 1)
        #expect(summary.missingSystemEvidenceCount == 0)
        #expect(summary.untrackedOwnedIdentifierCount == 1)
        #expect(summary.ignoredIdentifierCount == 1)
        #expect(summary.durableOutboxCount == 1)
        #expect(summary.requiresManualReview)
        #expect(try Data(contentsOf: file) == before)
        #expect(await port.counts() == [1, 1, 1, 0, 0])
        #expect(!String(reflecting: summary).contains("CONFIDENTIAL TITLE"))
    }
}

@Test func focusDiagnosticsDeniedCannotInterpretOSAbsenceAsNonDelivery() async throws {
    try await withDiagnosticsStore { store, file in
        _ = try await makeDiagnosticsOutbox(store: store)
        let port = FocusDiagnosticsCenterStub(authorization: .denied)
        let reader = FocusReminderNotificationDiagnosticsReader(
            store: store, gateway: FocusReminderNotificationGateway(center: port)
        )
        let before = try Data(contentsOf: file)
        let summary = try await reader.load()
        #expect(summary.authorization == .denied)
        #expect(summary.evidenceQuality == .authorizationRestricted)
        #expect(summary.observedOutboxCount == 0)
        #expect(summary.missingSystemEvidenceCount == 1)
        #expect(summary.requiresManualReview)
        #expect(try Data(contentsOf: file) == before)
        #expect(await port.counts() == [1, 1, 1, 0, 0])
    }
}

@Test func focusDiagnosticsUntrackedACKedRequestIsNeverRemoved() async throws {
    try await withDiagnosticsStore { store, file in
        let record = try await makeDiagnosticsOutbox(store: store)
        _ = try await store.acknowledge(outboxID: record.id)
        let owned = FocusReminderNotificationIdentity.identifier(for: record.id)
        let port = FocusDiagnosticsCenterStub(
            authorization: .provisional, delivered: [owned]
        )
        let reader = FocusReminderNotificationDiagnosticsReader(
            store: store, gateway: FocusReminderNotificationGateway(center: port)
        )
        let before = try Data(contentsOf: file)
        let summary = try await reader.load()
        #expect(summary.evidenceQuality == .nonAtomicSnapshot)
        #expect(summary.durableOutboxCount == 0)
        #expect(summary.untrackedOwnedIdentifierCount == 1)
        #expect(summary.requiresManualReview)
        #expect(try Data(contentsOf: file) == before)
        #expect(await port.counts() == [1, 1, 1, 0, 0])
    }
}

@Test func focusDiagnosticsRejectsInvalidAndOverLimitEvidenceWithoutMutations() async throws {
    try await withDiagnosticsStore { store, file in
        let record = try await makeDiagnosticsOutbox(store: store)
        let id = FocusReminderNotificationIdentity.identifier(for: record.id)
        let port = FocusDiagnosticsCenterStub(pending: [id, id], delivered: [id])
        let reader = FocusReminderNotificationDiagnosticsReader(
            store: store, gateway: FocusReminderNotificationGateway(center: port)
        )
        let before = try Data(contentsOf: file)
        await #expect(throws: FocusReminderNotificationReconciliationError.tooManySystemIdentifiers) {
            try await reader.load(maximumEvidenceCount: 0)
        }
        await #expect(throws: FocusReminderNotificationReconciliationError.tooManySystemIdentifiers) {
            try await reader.load(maximumEvidenceCount: 2)
        }
        #expect(try Data(contentsOf: file) == before)
        #expect(await port.counts() == [1, 1, 0, 0, 0])
    }
}

@Test func focusDiagnosticsInvalidBackingFileFailsBeforeOSRead() async throws {
    let url = try #require(URL(string: "https://invalid.example/focus.json"))
    let store = FocusReminderCollectionStore(fileURL: url)
    let port = FocusDiagnosticsCenterStub()
    let reader = FocusReminderNotificationDiagnosticsReader(
        store: store, gateway: FocusReminderNotificationGateway(center: port)
    )
    await #expect(throws: FocusReminderCollectionStore.StoreError.invalidBackingFile) {
        try await reader.load()
    }
    #expect(await port.counts() == [0, 0, 0, 0, 0])
}

@Test func focusDiagnosticsAuthorizedNoOSRecordStillRequiresReview() async throws {
    try await withDiagnosticsStore { store, _ in
        _ = try await makeDiagnosticsOutbox(store: store)
        let port = FocusDiagnosticsCenterStub(authorization: .authorized)
        let reader = FocusReminderNotificationDiagnosticsReader(
            store: store, gateway: FocusReminderNotificationGateway(center: port)
        )
        let summary = try await reader.load()
        #expect(summary.evidenceQuality == .nonAtomicSnapshot)
        #expect(summary.observedOutboxCount == 0)
        #expect(summary.missingSystemEvidenceCount == 1)
        #expect(summary.requiresManualReview)
        #expect(await port.counts() == [1, 1, 1, 0, 0])
    }
}

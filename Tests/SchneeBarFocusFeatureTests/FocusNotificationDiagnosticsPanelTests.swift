import Foundation
import SchneeBarFocusCore
import SchneeBarFocusPersistence
import SchneeBarFocusNotifications
@testable import SchneeBarFocusFeature
import Testing

private actor FocusPreviewNotificationPort: FocusReminderNotificationCenterPort {
    private let authorization: FocusReminderNotificationAuthorization
    private let pendingIDs: [String]
    private let deliveredIDs: [String]
    private var adds = 0
    private var removes = 0

    init(
        authorization: FocusReminderNotificationAuthorization = .authorized,
        pending: [String] = [],
        delivered: [String] = []
    ) {
        self.authorization = authorization
        pendingIDs = pending
        deliveredIDs = delivered
    }

    func authorizationStatus() async -> FocusReminderNotificationAuthorization { authorization }
    func pendingIdentifiers() async -> [String] { pendingIDs }
    func deliveredIdentifiers() async -> [String] { deliveredIDs }
    func add(_ request: FocusReminderNotificationRequest) async throws { adds += 1 }
    func remove(identifiers: [String]) async { removes += 1 }
    func mutations() -> (Int, Int) { (adds, removes) }
}

private func withFocusPreview(
    _ body: (FocusReminderCollectionStore, URL) async throws -> Void
) async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(
        at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700]
    )
    defer { try? FileManager.default.removeItem(at: directory) }
    let path = directory.appendingPathComponent("reminders.json")
    try await body(FocusReminderCollectionStore(fileURL: path), path)
}

private func createFocusPreviewOutbox(
    store: FocusReminderCollectionStore
) async throws -> FocusReminderOutboxRecord {
    let start = Date(timeIntervalSince1970: 1_700_000_000)
    let due = start.addingTimeInterval(60)
    let calendar = Calendar(identifier: .gregorian)
    let entry = try await store.add(title: "PRIVATE LOCAL TITLE", rule: .once(due))
    _ = try await store.apply(id: entry.id, command: .update(.setEnabled(true)), at: start)
    let planned = try await store.apply(
        id: entry.id, command: .update(.replan(calendar)), at: start
    )
    let ticket = try #require(planned.snapshot.entries.first?.state.pending)
    let claim = try await store.apply(
        id: entry.id, command: .update(.claim(ticketID: ticket.id, calendar: calendar)), at: due
    )
    return try #require(claim.enqueued)
}

@Test func focusDiagnosticsPreviewConstructsWithoutTouchingFileOrOS() async throws {
    try await withFocusPreview { store, path in
        let port = FocusPreviewNotificationPort()
        let reader = FocusReminderNotificationDiagnosticsReader(
            store: store, gateway: FocusReminderNotificationGateway(center: port)
        )
        await MainActor.run { _ = FocusNotificationDiagnosticsPanel(reader: reader) }
        #expect(!FileManager.default.fileExists(atPath: path.path))
        let mut = await port.mutations()
        #expect(mut.0 == 0 && mut.1 == 0)
    }
}

@Test func focusDiagnosticsPreviewEmptyEvidenceReadHasNoFileSideEffects() async throws {
    try await withFocusPreview { store, path in
        let port = FocusPreviewNotificationPort()
        let reader = FocusReminderNotificationDiagnosticsReader(
            store: store, gateway: FocusReminderNotificationGateway(center: port)
        )
        let summary = try await reader.load()
        #expect(summary.durableOutboxCount == 0)
        #expect(summary.untrackedOwnedIdentifierCount == 0)
        #expect(!summary.requiresManualReview)
        #expect(!FileManager.default.fileExists(atPath: path.path))
        let mut = await port.mutations()
        #expect(mut.0 == 0 && mut.1 == 0)
    }
}

@Test func focusDiagnosticsPreviewRetainsUncertainOutboxWithoutMutations() async throws {
    try await withFocusPreview { store, path in
        let record = try await createFocusPreviewOutbox(store: store)
        let port = FocusPreviewNotificationPort(authorization: .denied)
        let reader = FocusReminderNotificationDiagnosticsReader(
            store: store, gateway: FocusReminderNotificationGateway(center: port)
        )
        let before = try Data(contentsOf: path)
        let summary = try await reader.load()
        #expect(summary.authorization == .denied)
        #expect(summary.durableOutboxCount == 1)
        #expect(summary.missingSystemEvidenceCount == 1)
        #expect(summary.requiresManualReview)
        #expect(try Data(contentsOf: path) == before)
        let snapshot = try await store.load()
        #expect(snapshot.outbox == [record])
        let mut = await port.mutations()
        #expect(mut.0 == 0 && mut.1 == 0)
    }
}

@Test func focusDiagnosticsPreviewDoesNotDeleteUntrackedOSOwnedEvidence() async throws {
    try await withFocusPreview { store, path in
        let record = try await createFocusPreviewOutbox(store: store)
        _ = try await store.acknowledge(outboxID: record.id)
        let port = FocusPreviewNotificationPort(
            delivered: [FocusReminderNotificationIdentity.identifier(for: record.id)]
        )
        let reader = FocusReminderNotificationDiagnosticsReader(
            store: store, gateway: FocusReminderNotificationGateway(center: port)
        )
        let before = try Data(contentsOf: path)
        let summary = try await reader.load()
        #expect(summary.durableOutboxCount == 0)
        #expect(summary.untrackedOwnedIdentifierCount == 1)
        #expect(summary.requiresManualReview)
        #expect(try Data(contentsOf: path) == before)
        let mut = await port.mutations()
        #expect(mut.0 == 0 && mut.1 == 0)
    }
}

@Test func focusDiagnosticsPreviewUnsafeBackingFileFailsBeforeOSMutation() async throws {
    let url = try #require(URL(string: "https://invalid.example/reminders.json"))
    let port = FocusPreviewNotificationPort()
    let reader = FocusReminderNotificationDiagnosticsReader(
        store: FocusReminderCollectionStore(fileURL: url),
        gateway: FocusReminderNotificationGateway(center: port)
    )
    await MainActor.run { _ = FocusNotificationDiagnosticsPanel(reader: reader) }
    await #expect(throws: FocusReminderCollectionStore.StoreError.invalidBackingFile) {
        try await reader.load()
    }
    let mut = await port.mutations()
    #expect(mut.0 == 0 && mut.1 == 0)
}

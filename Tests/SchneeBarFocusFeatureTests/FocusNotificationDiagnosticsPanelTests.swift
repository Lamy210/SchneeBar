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

@MainActor
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

@Test @MainActor func focusDiagnosticsViewStateInitialReadClearsBusyAndCreatesNoFile() async throws {
    try await withFocusPreview { store, file in
        let port = FocusPreviewNotificationPort()
        let reader = FocusReminderNotificationDiagnosticsReader(
            store: store, gateway: FocusReminderNotificationGateway(center: port)
        )
        let state = FocusNotificationDiagnosticsViewState(reader: reader)
        #expect(state.diagnostics == nil)
        #expect(!state.isLoading)
        #expect(state.errorMessage == nil)
        await state.refresh()
        #expect(!state.isLoading)
        #expect(state.diagnostics?.durableOutboxCount == 0)
        #expect(state.errorMessage == nil)
        #expect(!FileManager.default.fileExists(atPath: file.path))
        let calls = await port.mutations()
        #expect(calls.0 == 0 && calls.1 == 0)
    }
}

@Test @MainActor func focusDiagnosticsViewStateHidesOldCountsOnInvalidBackingAndRecovers() async throws {
    try await withFocusPreview { store, file in
        let intent = try await createFocusPreviewOutbox(store: store)
        let port = FocusPreviewNotificationPort(
            pending: [FocusReminderNotificationIdentity.identifier(for: intent.id)]
        )
        let reader = FocusReminderNotificationDiagnosticsReader(
            store: store, gateway: FocusReminderNotificationGateway(center: port)
        )
        let state = FocusNotificationDiagnosticsViewState(reader: reader)
        let validBytes = try Data(contentsOf: file)
        await state.refresh()
        #expect(state.diagnostics?.observedOutboxCount == 1)
        #expect(state.errorMessage == nil)

        try Data("{invalid-json".utf8).write(to: file)
        await state.refresh()
        #expect(state.diagnostics == nil)
        #expect(!state.isLoading)
        #expect(state.errorMessage != nil)
        #expect(!(state.errorMessage ?? "").contains("PRIVATE LOCAL TITLE"))
        #expect(try Data(contentsOf: file) != validBytes)

        try validBytes.write(to: file)
        await state.refresh()
        #expect(state.diagnostics?.observedOutboxCount == 1)
        #expect(state.errorMessage == nil)
        #expect(!state.isLoading)
        let calls = await port.mutations()
        #expect(calls.0 == 0 && calls.1 == 0)
    }
}

@Test @MainActor func focusDiagnosticsViewStateRefreshReflectsExternalACKWithoutDeletion() async throws {
    try await withFocusPreview { store, file in
        let record = try await createFocusPreviewOutbox(store: store)
        let port = FocusPreviewNotificationPort(
            delivered: [FocusReminderNotificationIdentity.identifier(for: record.id)]
        )
        let reader = FocusReminderNotificationDiagnosticsReader(
            store: store, gateway: FocusReminderNotificationGateway(center: port)
        )
        let state = FocusNotificationDiagnosticsViewState(reader: reader)
        await state.refresh()
        #expect(state.diagnostics?.durableOutboxCount == 1)
        #expect(state.diagnostics?.observedOutboxCount == 1)
        #expect(state.diagnostics?.untrackedOwnedIdentifierCount == 0)

        _ = try await store.acknowledge(outboxID: record.id)
        let bytes = try Data(contentsOf: file)
        await state.refresh()
        #expect(state.diagnostics?.durableOutboxCount == 0)
        #expect(state.diagnostics?.untrackedOwnedIdentifierCount == 1)
        #expect(state.diagnostics?.requiresManualReview == true)
        #expect(state.errorMessage == nil)
        #expect(try Data(contentsOf: file) == bytes)
        let calls = await port.mutations()
        #expect(calls.0 == 0 && calls.1 == 0)
    }
}

private actor FocusPreviewPausedEvidencePort: FocusReminderNotificationCenterPort {
    private var started = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var resumeAuthorization: CheckedContinuation<Void, Never>?
    private var authorizationCalls = 0
    private var mutations = 0

    func authorizationStatus() async -> FocusReminderNotificationAuthorization {
        authorizationCalls += 1
        if authorizationCalls == 1 {
            // Suspend only the first sample. The gateway may take a second
            // authorization sample to detect permission drift; that read
            // must not deadlock this concurrency regression fixture.
            started = true
            for waiter in waiters { waiter.resume() }
            waiters.removeAll()
            await withCheckedContinuation { continuation in
                resumeAuthorization = continuation
            }
        }
        return .authorized
    }

    func pendingIdentifiers() async -> [String] { [] }
    func deliveredIdentifiers() async -> [String] { [] }
    func add(_ request: FocusReminderNotificationRequest) async throws { mutations += 1 }
    func remove(identifiers: [String]) async { mutations += 1 }

    func waitUntilAuthorizationStarted() async {
        if started { return }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    func releaseAuthorization() {
        resumeAuthorization?.resume()
        resumeAuthorization = nil
    }

    func counts() -> (authorization: Int, mutations: Int) {
        (authorizationCalls, mutations)
    }
}

@Test @MainActor func focusDiagnosticsViewStateRejectsOverlappingRefreshDuringOSWait() async throws {
    try await withFocusPreview { store, file in
        let port = FocusPreviewPausedEvidencePort()
        let reader = FocusReminderNotificationDiagnosticsReader(
            store: store, gateway: FocusReminderNotificationGateway(center: port)
        )
        let state = FocusNotificationDiagnosticsViewState(reader: reader)
        let first = Task { await state.refresh() }
        await port.waitUntilAuthorizationStarted()
        #expect(state.isLoading)
        #expect(state.diagnostics == nil)

        // This must return immediately instead of starting a second OS read.
        await state.refresh()
        let waiting = await port.counts()
        #expect(waiting.authorization == 1)
        #expect(waiting.mutations == 0)
        #expect(state.isLoading)

        await port.releaseAuthorization()
        await first.value
        #expect(!state.isLoading)
        #expect(state.errorMessage == nil)
        #expect(state.diagnostics?.durableOutboxCount == 0)
        #expect(!FileManager.default.fileExists(atPath: file.path))
        let after = await port.counts()
        // Both the original single-sample gateway and the fail-closed
        // two-sample authorization gateway must finish without a duplicate
        // refresh or a second suspended read.
        #expect((1...2).contains(after.authorization))
        #expect(after.mutations == 0)
    }
}

import Foundation
import SchneeBarFocusCore
import SchneeBarFocusPersistence
@testable import SchneeBarFocusNotifications
import Testing

private let triageOrigin = Date(timeIntervalSince1970: 1_700_000_000)
private let triageCalendar = Calendar(identifier: .gregorian)

private actor TriageNotificationCenter: FocusReminderNotificationCenterPort {
    let status: FocusReminderNotificationAuthorization
    let pending: [String]
    let delivered: [String]
    private var reads = 0
    private var additions = 0
    private var removals = 0

    init(
        status: FocusReminderNotificationAuthorization,
        pending: [String] = [],
        delivered: [String] = []
    ) {
        self.status = status
        self.pending = pending
        self.delivered = delivered
    }

    func authorizationStatus() async -> FocusReminderNotificationAuthorization {
        reads += 1
        return status
    }
    func pendingIdentifiers() async -> [String] {
        reads += 1
        return pending
    }
    func deliveredIdentifiers() async -> [String] {
        reads += 1
        return delivered
    }
    func add(_ request: FocusReminderNotificationRequest) async throws { additions += 1 }
    func remove(identifiers: [String]) async { removals += 1 }
    func activity() -> (Int, Int, Int) { (reads, additions, removals) }
}

private func withTriageStore(
    _ body: (FocusReminderCollectionStore, URL) async throws -> Void
) async throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(
        at: dir, withIntermediateDirectories: false,
        attributes: [.posixPermissions: 0o700]
    )
    defer { try? FileManager.default.removeItem(at: dir) }
    let file = dir.appendingPathComponent("reminders.json")
    try await body(FocusReminderCollectionStore(fileURL: file), file)
}

private func enqueueTriageReminder(
    _ store: FocusReminderCollectionStore,
    dueSeconds: TimeInterval
) async throws -> FocusReminderOutboxRecord {
    let due = triageOrigin.addingTimeInterval(dueSeconds)
    let entry = try await store.add(title: "Private title", rule: .once(due))
    _ = try await store.apply(
        id: entry.id, command: .update(.setEnabled(true)), at: triageOrigin
    )
    let planned = try await store.apply(
        id: entry.id, command: .update(.replan(triageCalendar)), at: triageOrigin
    )
    let ticket = try #require(
        planned.snapshot.entries.first(where: { $0.id == entry.id })?.state.pending
    )
    let claimed = try await store.apply(
        id: entry.id,
        command: .update(.claim(ticketID: ticket.id, calendar: triageCalendar)),
        at: due
    )
    return try #require(claimed.enqueued)
}

@Test func focusUnifiedTriageUsesOneSnapshotAndDoesNotMutateOutbox() async throws {
    try await withTriageStore { store, file in
        let observed = try await enqueueTriageReminder(store, dueSeconds: 60)
        let missing = try await enqueueTriageReminder(store, dueSeconds: 120)
        let unrelatedOwned = FocusReminderNotificationIdentity.identifier(for: UUID())
        let center = TriageNotificationCenter(
            status: .authorized,
            pending: [FocusReminderNotificationIdentity.identifier(for: observed.id)],
            delivered: [unrelatedOwned, "foreign.app.notification"]
        )
        let triage = FocusReminderRecoveryUnifiedTriage(
            store: store, gateway: FocusReminderNotificationGateway(center: center)
        )
        let before = try Data(contentsOf: file)
        let at = triageOrigin.addingTimeInterval(400)
        let result = try await triage.inspectOnce(at: at, agedAfter: 300)

        #expect(result.observationDate == at)
        #expect(result.preview.queuedOutboxCount == 2)
        #expect(result.preview.observedInSystemCount == 1)
        #expect(result.preview.candidateAcknowledgementCount == 1)
        #expect(result.preview.needsManualRecoveryCount == 1)
        #expect(result.preview.untrackedOwnedIdentifierCount == 1)
        #expect(result.preview.ignoredIdentifierCount == 1)
        #expect(result.backlog.queuedCount == result.preview.queuedOutboxCount)
        #expect(result.backlog.remainingCapacity == 126)
        #expect(result.backlog.agedCount == 1)
        #expect(result.backlog.oldestClaimedAt == observed.claimedAt)
        #expect(observed.claimedAt < missing.claimedAt)
        #expect(try Data(contentsOf: file) == before)
        let activity = await center.activity()
        #expect(activity.0 == 4 && activity.1 == 0 && activity.2 == 0)
    }
}

@Test func focusUnifiedTriageDeniedPermissionNeverYieldsActionableACK() async throws {
    try await withTriageStore { store, file in
        let queued = try await enqueueTriageReminder(store, dueSeconds: 120)
        let center = TriageNotificationCenter(
            status: .denied,
            pending: [FocusReminderNotificationIdentity.identifier(for: queued.id)]
        )
        let triage = FocusReminderRecoveryUnifiedTriage(
            store: store, gateway: FocusReminderNotificationGateway(center: center)
        )
        let before = try Data(contentsOf: file)
        let result = try await triage.inspectOnce(
            at: triageOrigin.addingTimeInterval(100), agedAfter: 0
        )
        #expect(!result.preview.permissionAllowsEvidence)
        #expect(result.preview.observedInSystemCount == 1)
        #expect(result.preview.candidateAcknowledgementCount == 0)
        #expect(result.preview.needsManualRecoveryCount == 1)
        #expect(result.backlog.futureClaimCount == 1)
        #expect(result.backlog.agedCount == 0)
        #expect(result.backlog.queuedCount == 1)
        #expect(try Data(contentsOf: file) == before)
        let activity = await center.activity()
        #expect(activity.1 == 0 && activity.2 == 0)
    }
}

@Test func focusUnifiedTriageRejectsInvalidClockAndThresholdBeforeOSRead() async throws {
    try await withTriageStore { store, _ in
        _ = try await enqueueTriageReminder(store, dueSeconds: 60)
        let center = TriageNotificationCenter(status: .authorized)
        let triage = FocusReminderRecoveryUnifiedTriage(
            store: store, gateway: FocusReminderNotificationGateway(center: center)
        )
        await #expect(throws: FocusReminderOutboxDiagnosticsError.invalidAgeThreshold) {
            try await triage.inspectOnce(at: triageOrigin, agedAfter: -1)
        }
        await #expect(throws: FocusReminderOutboxDiagnosticsError.invalidObservationDate) {
            try await triage.inspectOnce(
                at: Date(timeIntervalSince1970: .infinity), agedAfter: 300
            )
        }
        let activity = await center.activity()
        #expect(activity.0 == 0 && activity.1 == 0 && activity.2 == 0)
    }
}

@Test func focusUnifiedTriageEvidenceOverflowDoesNotAcknowledgeOrMutate() async throws {
    try await withTriageStore { store, file in
        let queued = try await enqueueTriageReminder(store, dueSeconds: 60)
        let center = TriageNotificationCenter(
            status: .authorized,
            pending: [FocusReminderNotificationIdentity.identifier(for: queued.id)],
            delivered: ["foreign.app.notification"]
        )
        let triage = FocusReminderRecoveryUnifiedTriage(
            store: store, gateway: FocusReminderNotificationGateway(center: center)
        )
        let before = try Data(contentsOf: file)
        await #expect(
            throws: FocusReminderNotificationReconciliationError.tooManySystemIdentifiers
        ) {
            try await triage.inspectOnce(
                at: triageOrigin.addingTimeInterval(400),
                agedAfter: 300,
                maximumEvidenceCount: 1
            )
        }
        #expect(try Data(contentsOf: file) == before)
        let activity = await center.activity()
        #expect(activity.1 == 0 && activity.2 == 0)
    }
}


private actor MutatingTriageNotificationCenter: FocusReminderNotificationCenterPort {
    private let store: FocusReminderCollectionStore
    private let toDisable: UUID
    private let observedIdentifier: String
    private var mutationSucceeded = false
    private var additions = 0
    private var removals = 0

    init(store: FocusReminderCollectionStore, toDisable: UUID, observedIdentifier: String) {
        self.store = store
        self.toDisable = toDisable
        self.observedIdentifier = observedIdentifier
    }

    func authorizationStatus() async -> FocusReminderNotificationAuthorization { .authorized }
    func pendingIdentifiers() async -> [String] {
        // Deliberately models an external change after triage loaded its file.
        do {
            _ = try await store.apply(
                id: toDisable,
                command: .update(.setEnabled(false)),
                at: triageOrigin.addingTimeInterval(300)
            )
            mutationSucceeded = true
        } catch {
            mutationSucceeded = false
        }
        return [observedIdentifier]
    }
    func deliveredIdentifiers() async -> [String] { [] }
    func add(_ request: FocusReminderNotificationRequest) async throws { additions += 1 }
    func remove(identifiers: [String]) async { removals += 1 }
    func activity() -> (Bool, Int, Int) { (mutationSucceeded, additions, removals) }
}

@Test func focusUnifiedTriageRemainsInternallyConsistentWhenStoreChangesDuringOSRead() async throws {
    try await withTriageStore { store, _ in
        let stale = try await enqueueTriageReminder(store, dueSeconds: 60)
        let surviving = try await enqueueTriageReminder(store, dueSeconds: 120)
        let center = MutatingTriageNotificationCenter(
            store: store,
            toDisable: stale.reminderID,
            observedIdentifier: FocusReminderNotificationIdentity.identifier(for: surviving.id)
        )
        let triage = FocusReminderRecoveryUnifiedTriage(
            store: store, gateway: FocusReminderNotificationGateway(center: center)
        )
        let report = try await triage.inspectOnce(
            at: triageOrigin.addingTimeInterval(400), agedAfter: 300
        )
        #expect(report.preview.queuedOutboxCount == 2)
        #expect(report.backlog.queuedCount == 2)
        #expect(report.preview.candidateAcknowledgementCount == 1)
        #expect(report.preview.needsManualRecoveryCount == 1)
        #expect(report.backlog.remainingCapacity == 126)

        // The external mutation is intentionally visible only in a NEW load:
        // an earlier preview must never be treated as an ACK authorization.
        #expect(try await store.load().outbox == [surviving])
        let activity = await center.activity()
        #expect(activity.0 && activity.1 == 0 && activity.2 == 0)
    }
}

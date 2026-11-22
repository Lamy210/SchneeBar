import Foundation
import SchneeBarFocusCore
import SchneeBarFocusPersistence
@testable import SchneeBarFocusNotifications
import Testing

private let recoveryOrigin = Date(timeIntervalSince1970: 1_700_000_000)
private let recoveryCalendar = Calendar(identifier: .gregorian)

private actor RecoveryEvidenceCenter: FocusReminderNotificationCenterPort {
    let status: FocusReminderNotificationAuthorization
    let pending: [String]
    let delivered: [String]
    private var additions = 0
    private var removals = 0

    init(status: FocusReminderNotificationAuthorization, pending: [String], delivered: [String]) {
        self.status = status
        self.pending = pending
        self.delivered = delivered
    }

    func authorizationStatus() async -> FocusReminderNotificationAuthorization { status }
    func pendingIdentifiers() async -> [String] { pending }
    func deliveredIdentifiers() async -> [String] { delivered }
    func add(_ request: FocusReminderNotificationRequest) async throws { additions += 1 }
    func remove(identifiers: [String]) async { removals += 1 }
    func sideEffects() -> (Int, Int) { (additions, removals) }
}

private actor InvalidatingRecoveryCenter: FocusReminderNotificationCenterPort {
    let store: FocusReminderCollectionStore
    let reminderToDisable: UUID
    let pending: [String]
    private var didInvalidate = false

    init(store: FocusReminderCollectionStore, reminderToDisable: UUID, pending: [String]) {
        self.store = store
        self.reminderToDisable = reminderToDisable
        self.pending = pending
    }

    func authorizationStatus() async -> FocusReminderNotificationAuthorization { .authorized }
    func pendingIdentifiers() async -> [String] {
        let result = try? await store.apply(id: reminderToDisable,
            command: .update(.setEnabled(false)), at: recoveryOrigin.addingTimeInterval(300))
        didInvalidate = result != nil
        return pending
    }
    func deliveredIdentifiers() async -> [String] { [] }
    func add(_ request: FocusReminderNotificationRequest) async throws {}
    func remove(identifiers: [String]) async {}
    func wasInvalidated() -> Bool { didInvalidate }
}

private func withRecoveryStore(
    _ body: (FocusReminderCollectionStore) async throws -> Void
) async throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: false,
                                           attributes: [.posixPermissions: 0o700])
    defer { try? FileManager.default.removeItem(at: dir) }
    try await body(FocusReminderCollectionStore(fileURL: dir.appendingPathComponent("reminders.json")))
}

private func makeRecoveryOutbox(
    _ store: FocusReminderCollectionStore, dueSeconds: TimeInterval
) async throws -> (UUID, FocusReminderOutboxRecord) {
    let due = recoveryOrigin.addingTimeInterval(dueSeconds)
    let entry = try await store.add(title: "private reminder", rule: .once(due))
    _ = try await store.apply(id: entry.id,
        command: .update(.setEnabled(true)), at: recoveryOrigin)
    let planned = try await store.apply(id: entry.id,
        command: .update(.replan(recoveryCalendar)), at: recoveryOrigin)
    let ticket = try #require(planned.snapshot.entries.first(where: { $0.id == entry.id })?.state.pending)
    let claimed = try await store.apply(id: entry.id,
        command: .update(.claim(ticketID: ticket.id, calendar: recoveryCalendar)), at: due)
    return (entry.id, try #require(claimed.enqueued))
}

@Test func focusAcceptedRecoveryAcksOnlyOSObservedRequests() async throws {
    try await withRecoveryStore { store in
        let (_, accepted) = try await makeRecoveryOutbox(store, dueSeconds: 60)
        let (_, unknown) = try await makeRecoveryOutbox(store, dueSeconds: 120)
        let id = FocusReminderNotificationIdentity.identifier(for: accepted.id)
        let center = RecoveryEvidenceCenter(
            status: .authorized, pending: [id], delivered: ["other.application"]
        )
        let recovery = FocusReminderAcceptedRequestRecovery(
            store: store, gateway: FocusReminderNotificationGateway(center: center)
        )
        let report = try await recovery.recoverOnce()
        #expect(report.authorization == .authorized && report.permissionAllowsEvidence)
        #expect(report.acknowledgedCount == 1 && report.needsManualRecoveryCount == 1)
        #expect(report.untrackedOwnedIdentifierCount == 0 && report.ignoredIdentifierCount == 1)
        let remaining = try await store.load()
        #expect(remaining.outbox == [unknown])
        let second = try await recovery.recoverOnce()
        #expect(second.acknowledgedCount == 0 && second.needsManualRecoveryCount == 1)
        let effects = await center.sideEffects()
        #expect(effects.0 == 0 && effects.1 == 0)
    }
}

@Test func focusAcceptedRecoveryHoldsMissingEvidenceWithoutResubmit() async throws {
    try await withRecoveryStore { store in
        let (_, pending) = try await makeRecoveryOutbox(store, dueSeconds: 60)
        let center = RecoveryEvidenceCenter(status: .provisional, pending: [], delivered: [])
        let recovery = FocusReminderAcceptedRequestRecovery(
            store: store, gateway: FocusReminderNotificationGateway(center: center)
        )
        let report = try await recovery.recoverOnce()
        #expect(report.authorization == .provisional && report.permissionAllowsEvidence)
        #expect(report.acknowledgedCount == 0 && report.needsManualRecoveryCount == 1)
        let snapshot = try await store.load()
        #expect(snapshot.outbox == [pending])
        let effects = await center.sideEffects()
        #expect(effects.0 == 0 && effects.1 == 0)
    }
}

@Test func focusAcceptedRecoveryRejectsOSObservationWithoutAuthorization() async throws {
    try await withRecoveryStore { store in
        let (_, pending) = try await makeRecoveryOutbox(store, dueSeconds: 60)
        let id = FocusReminderNotificationIdentity.identifier(for: pending.id)
        for status: FocusReminderNotificationAuthorization in [.denied, .notDetermined, .unsupported] {
            let center = RecoveryEvidenceCenter(status: status, pending: [id], delivered: [])
            let recovery = FocusReminderAcceptedRequestRecovery(
                store: store, gateway: FocusReminderNotificationGateway(center: center)
            )
            let report = try await recovery.recoverOnce()
            #expect(!report.permissionAllowsEvidence && report.acknowledgedCount == 0)
            #expect(report.needsManualRecoveryCount == 1)
            let snapshot = try await store.load()
            #expect(snapshot.outbox == [pending])
            let effects = await center.sideEffects()
            #expect(effects.0 == 0 && effects.1 == 0)
        }
    }
}

@Test func focusAcceptedRecoveryConcurrentDisableAbortsEntireBatch() async throws {
    try await withRecoveryStore { store in
        let (firstID, first) = try await makeRecoveryOutbox(store, dueSeconds: 60)
        let (_, second) = try await makeRecoveryOutbox(store, dueSeconds: 120)
        let center = InvalidatingRecoveryCenter(store: store,
            reminderToDisable: firstID,
            pending: [
                FocusReminderNotificationIdentity.identifier(for: first.id),
                FocusReminderNotificationIdentity.identifier(for: second.id),
            ]
        )
        let recovery = FocusReminderAcceptedRequestRecovery(
            store: store, gateway: FocusReminderNotificationGateway(center: center)
        )
        await #expect(throws: FocusReminderCollectionStore.StoreError.staleOutbox) {
            try await recovery.recoverOnce()
        }
        #expect(await center.wasInvalidated())
        let snapshot = try await store.load()
        #expect(snapshot.outbox == [second])
    }
}


@Test func focusAcceptedRecoveryPreviewReportsWithoutAcknowledging() async throws {
    try await withRecoveryStore { store in
        let (_, observed) = try await makeRecoveryOutbox(store, dueSeconds: 60)
        let (_, missing) = try await makeRecoveryOutbox(store, dueSeconds: 120)
        let unrelatedOwned = FocusReminderNotificationIdentity.identifier(for: UUID())
        let center = RecoveryEvidenceCenter(
            status: .authorized,
            pending: [FocusReminderNotificationIdentity.identifier(for: observed.id)],
            delivered: [unrelatedOwned, "github-delivery-recovery:opaque"]
        )
        let recovery = FocusReminderAcceptedRequestRecovery(
            store: store, gateway: FocusReminderNotificationGateway(center: center)
        )
        let before = try await store.load()
        let first = try await recovery.previewOnce()
        let second = try await recovery.previewOnce()
        #expect(first == second)
        #expect(first.permissionAllowsEvidence)
        #expect(first.queuedOutboxCount == 2)
        #expect(first.observedInSystemCount == 1)
        #expect(first.candidateAcknowledgementCount == 1)
        #expect(first.needsManualRecoveryCount == 1)
        #expect(first.untrackedOwnedIdentifierCount == 1)
        #expect(first.ignoredIdentifierCount == 1)
        #expect(try await store.load() == before)
        #expect(before.outbox == [observed, missing])
        let effects = await center.sideEffects()
        #expect(effects.0 == 0 && effects.1 == 0)
    }
}

@Test func focusAcceptedRecoveryPreviewNeverTreatsDeniedEvidenceAsActionable() async throws {
    try await withRecoveryStore { store in
        let (_, outbox) = try await makeRecoveryOutbox(store, dueSeconds: 60)
        let identifier = FocusReminderNotificationIdentity.identifier(for: outbox.id)
        for authorization: FocusReminderNotificationAuthorization in
            [.denied, .notDetermined, .unsupported] {
            let center = RecoveryEvidenceCenter(
                status: authorization, pending: [identifier], delivered: []
            )
            let recovery = FocusReminderAcceptedRequestRecovery(
                store: store, gateway: FocusReminderNotificationGateway(center: center)
            )
            let preview = try await recovery.previewOnce()
            #expect(preview.authorization == authorization)
            #expect(!preview.permissionAllowsEvidence)
            #expect(preview.queuedOutboxCount == 1)
            #expect(preview.observedInSystemCount == 1)
            #expect(preview.candidateAcknowledgementCount == 0)
            #expect(preview.needsManualRecoveryCount == 1)
            #expect(try await store.load().outbox == [outbox])
            let effects = await center.sideEffects()
            #expect(effects.0 == 0 && effects.1 == 0)
        }
    }
}

@Test func focusAcceptedRecoveryPreviewFailsClosedOnEvidenceOverflow() async throws {
    try await withRecoveryStore { store in
        let (_, outbox) = try await makeRecoveryOutbox(store, dueSeconds: 60)
        let center = RecoveryEvidenceCenter(
            status: .authorized,
            pending: [FocusReminderNotificationIdentity.identifier(for: outbox.id)],
            delivered: ["another.app.notification"]
        )
        let recovery = FocusReminderAcceptedRequestRecovery(
            store: store, gateway: FocusReminderNotificationGateway(center: center)
        )
        await #expect(throws: FocusReminderNotificationReconciliationError.tooManySystemIdentifiers) {
            try await recovery.previewOnce(maximumEvidenceCount: 1)
        }
        #expect(try await store.load().outbox == [outbox])
        let effects = await center.sideEffects()
        #expect(effects.0 == 0 && effects.1 == 0)
    }
}


private actor ChangingRecoveryEvidenceCenter: FocusReminderNotificationCenterPort {
    private let laterAuthorization: FocusReminderNotificationAuthorization
    private let firstPending: [String]
    private let laterPending: [String]
    private var authorizationReads = 0
    private var pendingReads = 0
    private var additions = 0
    private var removals = 0

    init(laterAuthorization: FocusReminderNotificationAuthorization,
         firstPending: [String], laterPending: [String]) {
        self.laterAuthorization = laterAuthorization
        self.firstPending = firstPending
        self.laterPending = laterPending
    }

    func authorizationStatus() async -> FocusReminderNotificationAuthorization {
        authorizationReads += 1
        return authorizationReads == 1 ? .authorized : laterAuthorization
    }

    func pendingIdentifiers() async -> [String] {
        pendingReads += 1
        return pendingReads == 1 ? firstPending : laterPending
    }

    func deliveredIdentifiers() async -> [String] { [] }
    func add(_ request: FocusReminderNotificationRequest) async throws { additions += 1 }
    func remove(identifiers: [String]) async { removals += 1 }
    func counts() -> (Int, Int, Int, Int) {
        (authorizationReads, pendingReads, additions, removals)
    }
}

@Test func focusAcceptedRecoveryAbortsWhenPermissionRevokedBeforeAck() async throws {
    try await withRecoveryStore { store in
        let (_, intent) = try await makeRecoveryOutbox(store, dueSeconds: 60)
        let identifier = FocusReminderNotificationIdentity.identifier(for: intent.id)
        let center = ChangingRecoveryEvidenceCenter(
            laterAuthorization: .denied,
            firstPending: [identifier], laterPending: [identifier]
        )
        let recovery = FocusReminderAcceptedRequestRecovery(
            store: store, gateway: FocusReminderNotificationGateway(center: center)
        )
        await #expect(
            throws: FocusReminderAcceptedRequestRecoveryError.evidenceChangedDuringRecovery
        ) {
            try await recovery.recoverOnce()
        }
        #expect(try await store.load().outbox == [intent])
        let counts = await center.counts()
        #expect(counts.0 == 2 && counts.1 == 2)
        #expect(counts.2 == 0 && counts.3 == 0)
    }
}

@Test func focusAcceptedRecoveryAbortsWhenOSRequestDisappearsBeforeAck() async throws {
    try await withRecoveryStore { store in
        let (_, intent) = try await makeRecoveryOutbox(store, dueSeconds: 60)
        let identifier = FocusReminderNotificationIdentity.identifier(for: intent.id)
        let center = ChangingRecoveryEvidenceCenter(
            laterAuthorization: .authorized,
            firstPending: [identifier], laterPending: []
        )
        let recovery = FocusReminderAcceptedRequestRecovery(
            store: store, gateway: FocusReminderNotificationGateway(center: center)
        )
        await #expect(
            throws: FocusReminderAcceptedRequestRecoveryError.evidenceChangedDuringRecovery
        ) {
            try await recovery.recoverOnce()
        }
        #expect(try await store.load().outbox == [intent])
        let counts = await center.counts()
        #expect(counts.0 == 2 && counts.1 == 2)
        #expect(counts.2 == 0 && counts.3 == 0)
    }
}

@Test func focusAcceptedRecoveryRechecksMatchingEvidenceThenAcksExactlyOnce() async throws {
    try await withRecoveryStore { store in
        let (_, intent) = try await makeRecoveryOutbox(store, dueSeconds: 60)
        let identifier = FocusReminderNotificationIdentity.identifier(for: intent.id)
        let center = ChangingRecoveryEvidenceCenter(
            laterAuthorization: .authorized,
            firstPending: [identifier], laterPending: [identifier]
        )
        let recovery = FocusReminderAcceptedRequestRecovery(
            store: store, gateway: FocusReminderNotificationGateway(center: center)
        )
        let report = try await recovery.recoverOnce()
        #expect(report.acknowledgedCount == 1)
        #expect(try await store.load().outbox.isEmpty)
        let counts = await center.counts()
        #expect(counts.0 == 2 && counts.1 == 2)
        #expect(counts.2 == 0 && counts.3 == 0)
    }
}


@Test func focusAcceptedRecoveryRejectsNewCandidateAppearingDuringConfirmation() async throws {
    try await withRecoveryStore { store in
        let (_, first) = try await makeRecoveryOutbox(store, dueSeconds: 60)
        let (_, second) = try await makeRecoveryOutbox(store, dueSeconds: 120)
        let firstID = FocusReminderNotificationIdentity.identifier(for: first.id)
        let secondID = FocusReminderNotificationIdentity.identifier(for: second.id)
        let center = ChangingRecoveryEvidenceCenter(
            laterAuthorization: .authorized,
            firstPending: [firstID],
            laterPending: [firstID, secondID]
        )
        let recovery = FocusReminderAcceptedRequestRecovery(
            store: store, gateway: FocusReminderNotificationGateway(center: center)
        )
        await #expect(
            throws: FocusReminderAcceptedRequestRecoveryError.evidenceChangedDuringRecovery
        ) {
            try await recovery.recoverOnce()
        }
        #expect(try await store.load().outbox == [first, second])
        let counts = await center.counts()
        #expect(counts.0 == 2 && counts.1 == 2)
        #expect(counts.2 == 0 && counts.3 == 0)
    }
}

@Test func focusAcceptedRecoveryAllowsEquivalentReorderedOSCandidates() async throws {
    try await withRecoveryStore { store in
        let (_, first) = try await makeRecoveryOutbox(store, dueSeconds: 60)
        let (_, second) = try await makeRecoveryOutbox(store, dueSeconds: 120)
        let firstID = FocusReminderNotificationIdentity.identifier(for: first.id)
        let secondID = FocusReminderNotificationIdentity.identifier(for: second.id)
        let center = ChangingRecoveryEvidenceCenter(
            laterAuthorization: .authorized,
            firstPending: [firstID, secondID],
            laterPending: [secondID, firstID]
        )
        let recovery = FocusReminderAcceptedRequestRecovery(
            store: store, gateway: FocusReminderNotificationGateway(center: center)
        )
        let report = try await recovery.recoverOnce()
        #expect(report.acknowledgedCount == 2)
        #expect(report.needsManualRecoveryCount == 0)
        #expect(try await store.load().outbox.isEmpty)
        let counts = await center.counts()
        #expect(counts.0 == 2 && counts.1 == 2)
        #expect(counts.2 == 0 && counts.3 == 0)
    }
}

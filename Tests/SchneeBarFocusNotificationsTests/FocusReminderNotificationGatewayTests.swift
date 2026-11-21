import Foundation
import SchneeBarFocusCore
import SchneeBarFocusPersistence
@testable import SchneeBarFocusNotifications
import Testing

private enum FocusNotificationStubError: Error { case rejected }

private actor FocusNotificationCenterStub: FocusReminderNotificationCenterPort {
    let authorization: FocusReminderNotificationAuthorization
    let shouldReject: Bool
    private var submitted: [FocusReminderNotificationRequest] = []
    private var removed: [[String]] = []
    private var checks = 0
    private let pending: [String]
    private let delivered: [String]
    private var pendingReads = 0
    private var deliveredReads = 0

    init(authorization: FocusReminderNotificationAuthorization, shouldReject: Bool = false,
         pending: [String] = [], delivered: [String] = []) {
        self.authorization = authorization
        self.shouldReject = shouldReject
        self.pending = pending
        self.delivered = delivered
    }

    func authorizationStatus() async -> FocusReminderNotificationAuthorization {
        checks += 1
        return authorization
    }

    func add(_ request: FocusReminderNotificationRequest) async throws {
        if shouldReject { throw FocusNotificationStubError.rejected }
        submitted.append(request)
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
        removed.append(identifiers)
    }

    func snapshot() -> (checks: Int,
                        submitted: [FocusReminderNotificationRequest],
                        removed: [[String]], pendingReads: Int, deliveredReads: Int) {
        (checks, submitted, removed, pendingReads, deliveredReads)
    }
}

private func withFocusNotificationIntent(
    _ body: (FocusReminderOutboxRecord, FocusReminderCollectionStore) async throws -> Void
) async throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: false,
                                           attributes: [.posixPermissions: 0o700])
    defer { try? FileManager.default.removeItem(at: dir) }
    let store = FocusReminderCollectionStore(fileURL: dir.appendingPathComponent("reminders.json"))
    let initial = Date(timeIntervalSince1970: 1_700_000_000)
    let due = initial.addingTimeInterval(60)
    let calendar = Calendar(identifier: .gregorian)
    let entry = try await store.add(title: "PRIVATE USER TITLE", rule: .once(due))
    _ = try await store.apply(id: entry.id, command: .update(.setEnabled(true)), at: initial)
    let planned = try await store.apply(id: entry.id,
        command: .update(.replan(calendar)), at: initial)
    let ticket = try #require(planned.snapshot.entries.first?.state.pending)
    let claimed = try await store.apply(id: entry.id,
        command: .update(.claim(ticketID: ticket.id, calendar: calendar)), at: due)
    try await body(#require(claimed.enqueued), store)
}

@Test func focusNotificationGatewayRequiresExistingAuthorizationWithoutPrompt() async throws {
    try await withFocusNotificationIntent { intent, _ in
        for status: FocusReminderNotificationAuthorization in [
            .notDetermined, .denied, .unsupported,
        ] {
            let port = FocusNotificationCenterStub(authorization: status)
            let gateway = FocusReminderNotificationGateway(center: port)
            let outcome = try await gateway.submit(intent)
            #expect(outcome == .authorizationUnavailable)
            let result = await port.snapshot()
            #expect(result.checks == 1 && result.submitted.isEmpty && result.removed.isEmpty)
        }
    }
}

@Test func focusNotificationGatewayUsesNamespacedPrivateImmediateRequest() async throws {
    try await withFocusNotificationIntent { intent, store in
        for status: FocusReminderNotificationAuthorization in [.authorized, .provisional] {
            let port = FocusNotificationCenterStub(authorization: status)
            let gateway = FocusReminderNotificationGateway(center: port)
            let outcome = try await gateway.submit(intent)
            #expect(outcome == .accepted)
            let request = try #require(await port.snapshot().submitted.first)
            #expect(request.identifier == FocusReminderNotificationGateway.identifier(for: intent.id))
            #expect(request.identifier.hasPrefix("dev.lamy.schneebar.focus."))
            #expect(request.title == "Reminder")
            #expect(request.body == "A scheduled reminder is ready.")
            let text = request.title + request.body + request.identifier
            #expect(!text.contains("PRIVATE USER TITLE"))
            #expect(!text.contains("github-delivery-recovery"))
            #expect(!text.contains(intent.reminderID.uuidString))
            // Adapter acceptance does not silently ACK the authoritative outbox.
            let saved = try await store.load()
            #expect(saved.outbox == [intent])
        }
    }
}

@Test func focusNotificationGatewayStableIdsAndScopedCancel() async throws {
    try await withFocusNotificationIntent { intent, _ in
        let port = FocusNotificationCenterStub(authorization: .authorized)
        let gateway = FocusReminderNotificationGateway(center: port)
        let firstOutcome = try await gateway.submit(intent)
        let secondOutcome = try await gateway.submit(intent)
        #expect(firstOutcome == .accepted && secondOutcome == .accepted)
        await gateway.cancel(outboxID: intent.id)
        let state = await port.snapshot()
        let id = FocusReminderNotificationGateway.identifier(for: intent.id)
        #expect(state.submitted.map(\.identifier) == [id, id])
        #expect(state.removed == [[id]])
        #expect(!id.hasPrefix("github-delivery-recovery:"))
    }
}

@Test func focusNotificationGatewaySubmissionFailurePreservesDurableOutbox() async throws {
    try await withFocusNotificationIntent { intent, store in
        let port = FocusNotificationCenterStub(authorization: .authorized, shouldReject: true)
        let gateway = FocusReminderNotificationGateway(center: port)
        await #expect(throws: FocusNotificationStubError.rejected) {
            try await gateway.submit(intent)
        }
        let saved = try await store.load()
        #expect(saved.outbox == [intent])
        #expect(await port.snapshot().submitted.isEmpty)
    }
}

@Test func focusNotificationInspectionJoinsSystemEvidenceWithoutSideEffects() async throws {
    try await withFocusNotificationIntent { intent, store in
        let id = FocusReminderNotificationIdentity.identifier(for: intent.id)
        let orphan = FocusReminderNotificationIdentity.identifier(for: UUID())
        let port = FocusNotificationCenterStub(
            authorization: .authorized, pending: [id, id, "github-recovery:other"],
            delivered: [orphan, id]
        )
        let gateway = FocusReminderNotificationGateway(center: port)
        let snapshot = try await store.load()
        let inspection = try await gateway.inspect(snapshot)
        #expect(inspection.evidence.authorization == .authorized)
        #expect(inspection.evidence.pendingIdentifiers == [id, id, "github-recovery:other"])
        #expect(inspection.evidence.deliveredIdentifiers == [orphan, id])
        #expect(inspection.plan.observedInSystem == [intent])
        #expect(inspection.plan.missingSystemEvidence.isEmpty)
        #expect(inspection.plan.untrackedOwnedIdentifiers == [orphan])
        #expect(inspection.plan.ignoredIdentifierCount == 1)
        let calls = await port.snapshot()
        #expect(calls.checks == 1 && calls.pendingReads == 1 && calls.deliveredReads == 1)
        #expect(calls.submitted.isEmpty && calls.removed.isEmpty)
        let after = try await store.load()
        #expect(after == snapshot)
    }
}

@Test func focusNotificationInspectionRetainsDeniedStatusAndAmbiguousAbsence() async throws {
    try await withFocusNotificationIntent { intent, store in
        let port = FocusNotificationCenterStub(authorization: .denied)
        let gateway = FocusReminderNotificationGateway(center: port)
        let initial = try await store.load()
        let inspection = try await gateway.inspect(initial)
        #expect(inspection.evidence.authorization == .denied)
        #expect(inspection.plan.observedInSystem.isEmpty)
        #expect(inspection.plan.missingSystemEvidence == [intent])
        #expect(inspection.plan.untrackedOwnedIdentifiers.isEmpty)
        let status = await port.snapshot()
        #expect(status.submitted.isEmpty && status.removed.isEmpty)
        let saved = try await store.load()
        #expect(saved.outbox == [intent])
    }
}

@Test func focusNotificationInspectionBoundsOSResultsAndRejectsInvalidLimits() async throws {
    try await withFocusNotificationIntent { intent, store in
        let id = FocusReminderNotificationIdentity.identifier(for: intent.id)
        let port = FocusNotificationCenterStub(
            authorization: .provisional, pending: [id, id], delivered: [id]
        )
        let gateway = FocusReminderNotificationGateway(center: port)
        await #expect(throws: FocusReminderNotificationReconciliationError.tooManySystemIdentifiers) {
            try await gateway.observe(maximumEvidenceCount: 0)
        }
        await #expect(throws: FocusReminderNotificationReconciliationError.tooManySystemIdentifiers) {
            try await gateway.observe(maximumEvidenceCount: 1)
        }
        await #expect(throws: FocusReminderNotificationReconciliationError.tooManySystemIdentifiers) {
            try await gateway.observe(maximumEvidenceCount: 2)
        }
        let status = await port.snapshot()
        #expect(status.pendingReads == 2 && status.deliveredReads == 1)
        #expect(status.submitted.isEmpty && status.removed.isEmpty)
        let initial = try await store.load()
        let inspection = try await gateway.inspect(initial, maximumEvidenceCount: 3)
        #expect(inspection.plan.observedInSystem == [intent])
        #expect(inspection.plan.ignoredIdentifierCount == 0)
    }
}

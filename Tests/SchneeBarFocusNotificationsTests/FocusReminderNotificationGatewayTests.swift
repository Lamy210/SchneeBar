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

    init(authorization: FocusReminderNotificationAuthorization, shouldReject: Bool = false) {
        self.authorization = authorization
        self.shouldReject = shouldReject
    }

    func authorizationStatus() async -> FocusReminderNotificationAuthorization {
        checks += 1
        return authorization
    }

    func add(_ request: FocusReminderNotificationRequest) async throws {
        if shouldReject { throw FocusNotificationStubError.rejected }
        submitted.append(request)
    }

    func remove(identifiers: [String]) async {
        removed.append(identifiers)
    }

    func snapshot() -> (checks: Int,
                        submitted: [FocusReminderNotificationRequest],
                        removed: [[String]]) {
        (checks, submitted, removed)
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

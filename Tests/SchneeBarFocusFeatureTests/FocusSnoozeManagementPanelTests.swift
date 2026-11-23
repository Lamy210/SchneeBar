import Foundation
import SchneeBarFocusCore
import SchneeBarFocusPersistence
@testable import SchneeBarFocusFeature
import Testing

private let manageStart = Date(timeIntervalSince1970: 1_700_000_000)
private let manageDue = manageStart.addingTimeInterval(60)
private let manageCalendar = Calendar(identifier: .gregorian)

private func withManageFile(
    _ body: (FocusReminderCollectionStore, URL) async throws -> Void
) async throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: false,
                                           attributes: [.posixPermissions: 0o700])
    defer { try? FileManager.default.removeItem(at: dir) }
    let file = dir.appendingPathComponent("reminders.json")
    try await body(FocusReminderCollectionStore(fileURL: file), file)
}

private func makeManageSnooze(
    _ store: FocusReminderCollectionStore,
    title: String,
    due: Date
) async throws -> (UUID, FocusReminderState.SnoozeTicket) {
    let reminder = try await store.add(title: title, rule: .once(due))
    _ = try await store.apply(id: reminder.id, command: .update(.setEnabled(true)), at: manageStart)
    let plan = try await store.apply(id: reminder.id,
        command: .update(.replan(manageCalendar)), at: manageStart)
    let regular = try #require(plan.snapshot.entries.first(where: { $0.id == reminder.id })?.state.pending)
    _ = try await store.apply(id: reminder.id,
        command: .update(.claim(ticketID: regular.id, calendar: manageCalendar)), at: due)
    let delayed = try await store.apply(id: reminder.id,
        command: .update(.snooze(sourceTicketID: regular.id, seconds: 300)), at: due)
    return (reminder.id, try #require(
        delayed.snapshot.entries.first(where: { $0.id == reminder.id })?.state.pendingSnooze
    ))
}

@Test func focusSnoozeManagementEmptyLoadDoesNotCreateBackingFile() async throws {
    try await withManageFile { store, file in
        let coordinator = FocusSnoozeManagementCoordinator(store: store)
        let preview = try await coordinator.load()
        #expect(preview.rows.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: file.path))
    }
}

@Test func focusSnoozeManagementCancelPendingUpdatesPreviewAndPreservesOther() async throws {
    try await withManageFile { store, file in
        let (firstID, first) = try await makeManageSnooze(store, title: "First", due: manageDue)
        let (secondID, second) = try await makeManageSnooze(
            store, title: "Second", due: manageDue.addingTimeInterval(600)
        )
        let coordinator = FocusSnoozeManagementCoordinator(store: store)
        let initial = try await coordinator.load()
        #expect(initial.rows.map(\.id.reminderID) == [firstID, secondID])
        let updated = try await coordinator.cancelPending(reminderID: firstID, ticketID: first.id)
        #expect(updated.rows.count == 1)
        #expect(updated.rows.first?.id.ticketID == second.id)
        #expect(updated.rows.first?.phase == .pending)
        let reopened = FocusSnoozeManagementCoordinator(
            store: FocusReminderCollectionStore(fileURL: file)
        )
        let restored = try await reopened.load()
        #expect(restored == updated)
    }
}

@Test func focusSnoozeManagementStaleSnapshotCannotCancelClaimedOutbox() async throws {
    try await withManageFile { store, file in
        let (id, snooze) = try await makeManageSnooze(store, title: "Queued", due: manageDue)
        let coordinator = FocusSnoozeManagementCoordinator(store: store)
        let stalePreview = try await coordinator.load()
        #expect(stalePreview.rows.first?.phase == .pending)
        let claimed = try await store.apply(id: id,
            command: .update(.claimSnooze(ticketID: snooze.id)), at: snooze.deadline)
        let outbox = try #require(claimed.enqueued)
        let bytes = try Data(contentsOf: file)
        await #expect(throws: FocusReminderState.StateError.staleTicket) {
            try await coordinator.cancelPending(reminderID: id, ticketID: snooze.id)
        }
        #expect(try Data(contentsOf: file) == bytes)
        let updated = try await coordinator.load()
        #expect(updated.rows.count == 1)
        #expect(updated.rows.first?.phase == .unacknowledgedOutbox)
        #expect(updated.rows.first?.id.ticketID == outbox.ticketID)
        _ = try await store.acknowledge(outboxID: outbox.id)
        let afterAck = try await coordinator.load()
        #expect(afterAck.rows.isEmpty)
    }
}

@Test func focusSnoozeManagementWrongReminderAndReplayFailClosed() async throws {
    try await withManageFile { store, file in
        let (id, snooze) = try await makeManageSnooze(store, title: "Bound", due: manageDue)
        let controller = FocusSnoozeManagementCoordinator(store: store)
        let bytes = try Data(contentsOf: file)
        await #expect(throws: FocusReminderCollectionStore.StoreError.staleReminder) {
            try await controller.cancelPending(reminderID: UUID(), ticketID: snooze.id)
        }
        await #expect(throws: FocusReminderState.StateError.staleTicket) {
            try await controller.cancelPending(reminderID: id, ticketID: UUID())
        }
        #expect(try Data(contentsOf: file) == bytes)
        _ = try await controller.cancelPending(reminderID: id, ticketID: snooze.id)
        await #expect(throws: FocusReminderState.StateError.staleTicket) {
            try await controller.cancelPending(reminderID: id, ticketID: snooze.id)
        }
    }
}

@Test func focusSnoozeManagementWriteFailureDoesNotFalselyReportSuccess() async throws {
    try await withManageFile { store, file in
        let (id, snooze) = try await makeManageSnooze(store, title: "Retry", due: manageDue)
        let before = try Data(contentsOf: file)
        // A non-file URL is a guaranteed rejection at the persistence boundary.
        // The public initializer deliberately does not expose injected writers.
        let invalid = try #require(URL(string: "https://invalid.example/reminders.json"))
        let coordinator = FocusSnoozeManagementCoordinator(
            store: FocusReminderCollectionStore(fileURL: invalid)
        )
        await #expect(throws: FocusReminderCollectionStore.StoreError.invalidBackingFile) {
            try await coordinator.cancelPending(reminderID: id, ticketID: snooze.id)
        }
        #expect(try Data(contentsOf: file) == before)
        let recovered = FocusSnoozeManagementCoordinator(store: store)
        let afterFailure = try await recovered.load()
        #expect(afterFailure.rows.first?.phase == .pending)
        let afterRetry = try await recovered.cancelPending(reminderID: id, ticketID: snooze.id)
        #expect(afterRetry.rows.isEmpty)
    }
}

@Test func focusSnoozeManagementSwiftUIViewConstructsWithoutPersistenceEffects() async throws {
    try await withManageFile { store, file in
        let (id, _) = try await makeManageSnooze(store, title: "UI", due: manageDue)
        let coordinator = FocusSnoozeManagementCoordinator(store: store)
        let snapshot = try await coordinator.load()
        #expect(snapshot.rows.first?.id.reminderID == id)
        let bytes = try Data(contentsOf: file)
        await MainActor.run { _ = FocusSnoozeManagementPanel(coordinator: coordinator) }
        #expect(try Data(contentsOf: file) == bytes)
    }
}

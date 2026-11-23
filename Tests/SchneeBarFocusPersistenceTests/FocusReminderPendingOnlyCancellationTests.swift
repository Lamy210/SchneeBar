import Foundation
import SchneeBarFocusCore
@testable import SchneeBarFocusPersistence
import Testing

private let pendingCancelStart = Date(timeIntervalSince1970: 1_700_000_000)
private let pendingCancelDue = pendingCancelStart.addingTimeInterval(60)
private let pendingCancelCalendar = Calendar(identifier: .gregorian)

private func withPendingOnlyFile(
    _ body: (FocusReminderCollectionStore, URL) async throws -> Void
) async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false,
                                           attributes: [.posixPermissions: 0o700])
    defer { try? FileManager.default.removeItem(at: directory) }
    let file = directory.appendingPathComponent("reminders.json")
    try await body(FocusReminderCollectionStore(fileURL: file), file)
}

private func preparePendingOnly(
    _ store: FocusReminderCollectionStore, title: String = "First",
    due: Date = pendingCancelDue
) async throws -> (UUID, FocusReminderState.Ticket, FocusReminderState.SnoozeTicket) {
    let entry = try await store.add(title: title, rule: .once(due))
    _ = try await store.apply(id: entry.id, command: .update(.setEnabled(true)), at: pendingCancelStart)
    let planned = try await store.apply(id: entry.id,
        command: .update(.replan(pendingCancelCalendar)), at: pendingCancelStart)
    let original = try #require(planned.snapshot.entries.first(where: { $0.id == entry.id })?.state.pending)
    _ = try await store.apply(id: entry.id,
        command: .update(.claim(ticketID: original.id, calendar: pendingCancelCalendar)), at: due)
    let delayed = try await store.apply(id: entry.id,
        command: .update(.snooze(sourceTicketID: original.id, seconds: 300)), at: due)
    let snooze = try #require(delayed.snapshot.entries.first(where: { $0.id == entry.id })?.state.pendingSnooze)
    return (entry.id, original, snooze)
}

@Test func pendingOnlySnoozeCancelAfterRestartPreservesCursorAndBlocksReplay() async throws {
    try await withPendingOnlyFile { store, file in
        let (id, regular, snooze) = try await preparePendingOnly(store)
        let rebooted = FocusReminderCollectionStore(fileURL: file)
        let after = try await rebooted.cancelPendingSnooze(reminderID: id, ticketID: snooze.id)
        let state = try #require(after.entries.first(where: { $0.id == id })?.state)
        #expect(state.pendingSnooze == nil)
        #expect(state.snoozeOpportunity == nil)
        #expect(state.lastObserved == regular.occurrence)
        #expect(after.outbox.isEmpty)
        #expect(try await store.load() == after)
        let beforeReplay = try Data(contentsOf: file)
        await #expect(throws: FocusReminderState.StateError.staleTicket) {
            try await rebooted.cancelPendingSnooze(reminderID: id, ticketID: snooze.id)
        }
        #expect(try Data(contentsOf: file) == beforeReplay)
    }
}

@Test func pendingOnlySnoozeCancelRejectsClaimedOutboxAndNeverRevokesIt() async throws {
    try await withPendingOnlyFile { store, file in
        let (id, _, snooze) = try await preparePendingOnly(store)
        let claimed = try await store.apply(id: id,
            command: .update(.claimSnooze(ticketID: snooze.id)), at: snooze.deadline)
        let event = try #require(claimed.enqueued)
        let before = try Data(contentsOf: file)
        await #expect(throws: FocusReminderState.StateError.staleTicket) {
            try await store.cancelPendingSnooze(reminderID: id, ticketID: snooze.id)
        }
        #expect(try Data(contentsOf: file) == before)
        #expect(try await store.load().outbox == [event])
        // Even after an OS-acceptance ACK, the same ticket must not
        // accidentally become locally cancelable again.
        _ = try await store.acknowledge(outboxID: event.id)
        await #expect(throws: FocusReminderState.StateError.staleTicket) {
            try await store.cancelPendingSnooze(reminderID: id, ticketID: snooze.id)
        }
    }
}

@Test func pendingOnlySnoozeCancelRejectsForeignTicketWithoutTouchingOtherReminder() async throws {
    try await withPendingOnlyFile { store, file in
        let (firstID, _, firstTicket) = try await preparePendingOnly(store)
        let (secondID, _, secondTicket) = try await preparePendingOnly(
            store, title: "Second", due: pendingCancelDue.addingTimeInterval(600)
        )
        let before = try Data(contentsOf: file)
        await #expect(throws: FocusReminderState.StateError.staleTicket) {
            try await store.cancelPendingSnooze(reminderID: firstID, ticketID: secondTicket.id)
        }
        await #expect(throws: FocusReminderCollectionStore.StoreError.staleReminder) {
            try await store.cancelPendingSnooze(reminderID: UUID(), ticketID: firstTicket.id)
        }
        #expect(try Data(contentsOf: file) == before)
        let result = try await store.cancelPendingSnooze(reminderID: secondID, ticketID: secondTicket.id)
        #expect(result.entries.first(where: { $0.id == firstID })?.state.pendingSnooze == firstTicket)
        #expect(result.entries.first(where: { $0.id == secondID })?.state.pendingSnooze == nil)
    }
}

@Test func pendingOnlySnoozeCancelWriteFailureLeavesOriginalTicketAndBytes() async throws {
    enum Failure: Error { case denied }
    try await withPendingOnlyFile { store, file in
        let (id, _, snooze) = try await preparePendingOnly(store)
        let before = try Data(contentsOf: file)
        let failing = FocusReminderCollectionStore(fileURL: file,
            read: { try Data(contentsOf: $0) }, write: { _, _ in throw Failure.denied })
        await #expect(throws: Failure.denied) {
            try await failing.cancelPendingSnooze(reminderID: id, ticketID: snooze.id)
        }
        #expect(try Data(contentsOf: file) == before)
        #expect(try await store.load().entries.first(where: { $0.id == id })?.state.pendingSnooze == snooze)
        let retried = try await store.cancelPendingSnooze(reminderID: id, ticketID: snooze.id)
        #expect(retried.entries.first(where: { $0.id == id })?.state.pendingSnooze == nil)
    }
}

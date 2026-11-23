import Foundation
import SchneeBarFocusCore
@testable import SchneeBarFocusPersistence
import Testing

private let cancelStart = Date(timeIntervalSince1970: 1_700_000_000)
private let cancelDue = cancelStart.addingTimeInterval(60)
private let cancelCalendar = Calendar(identifier: .gregorian)

private func withCancellationFile(_ body: (URL) async throws -> Void) async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false,
                                           attributes: [.posixPermissions: 0o700])
    defer { try? FileManager.default.removeItem(at: directory) }
    try await body(directory.appendingPathComponent("reminders.json"))
}

private func prepareCancellationSnooze(_ store: FocusReminderCollectionStore) async throws
    -> (UUID, FocusReminderState.Ticket, FocusReminderState.SnoozeTicket) {
    let entry = try await store.add(title: "Cancel test", rule: .once(cancelDue))
    _ = try await store.apply(id: entry.id, command: .update(.setEnabled(true)), at: cancelStart)
    let planned = try await store.apply(id: entry.id, command: .update(.replan(cancelCalendar)), at: cancelStart)
    let original = try #require(planned.snapshot.entries.first?.state.pending)
    _ = try await store.apply(id: entry.id,
        command: .update(.claim(ticketID: original.id, calendar: cancelCalendar)), at: cancelDue)
    let delayed = try await store.apply(id: entry.id,
        command: .update(.snooze(sourceTicketID: original.id, seconds: 300)), at: cancelDue)
    let snooze = try #require(delayed.snapshot.entries.first?.state.pendingSnooze)
    #expect(delayed.snapshot.outbox.isEmpty)
    return (entry.id, original, snooze)
}

@Test func reminderPendingSnoozeCancelAfterRestartIsTicketBoundAndOneShot() async throws {
    try await withCancellationFile { file in
        let store = FocusReminderCollectionStore(fileURL: file)
        let (id, original, pending) = try await prepareCancellationSnooze(store)
        let before = try await store.load()
        let restarted = FocusReminderCollectionStore(fileURL: file)
        await #expect(throws: FocusReminderState.StateError.staleTicket) {
            try await restarted.apply(id: id,
                command: .update(.cancelSnooze(ticketID: UUID())), at: cancelDue)
        }
        #expect(try await restarted.load() == before)
        let cancelled = try await restarted.apply(id: id,
            command: .update(.cancelSnooze(ticketID: pending.id)), at: cancelDue)
        #expect(cancelled.claimed == nil && cancelled.claimedSnooze == nil && cancelled.enqueued == nil)
        #expect(cancelled.snapshot.entries.first?.state.pendingSnooze == nil)
        #expect(cancelled.snapshot.entries.first?.state.snoozeOpportunity == nil)
        #expect(cancelled.snapshot.entries.first?.state.lastObserved == original.occurrence)
        #expect(cancelled.snapshot.outbox.isEmpty)
        #expect(try await store.load() == cancelled.snapshot)
        await #expect(throws: FocusReminderState.StateError.staleTicket) {
            try await store.apply(id: id,
                command: .update(.claimSnooze(ticketID: pending.id)), at: pending.deadline)
        }
        await #expect(throws: FocusReminderState.StateError.staleTicket) {
            try await store.apply(id: id,
                command: .update(.cancelSnooze(ticketID: pending.id)), at: pending.deadline)
        }
    }
}

@Test func reminderClaimedSnoozeCanRevokeOnlyUnacknowledgedOutboxIntent() async throws {
    try await withCancellationFile { file in
        let store = FocusReminderCollectionStore(fileURL: file)
        let (id, original, snooze) = try await prepareCancellationSnooze(store)
        let claimed = try await store.apply(id: id,
            command: .update(.claimSnooze(ticketID: snooze.id)), at: snooze.deadline)
        let event = try #require(claimed.enqueued)
        #expect(event.kind == .snooze && event.ticketID == snooze.id)
        #expect(claimed.snapshot.outbox == [event])
        let cancelled = try await store.apply(id: id,
            command: .update(.cancelSnooze(ticketID: snooze.id)), at: snooze.deadline)
        #expect(cancelled.snapshot.outbox.isEmpty)
        #expect(cancelled.snapshot.entries.first?.state.lastObserved == original.occurrence)
        #expect(try await FocusReminderCollectionStore(fileURL: file).load() == cancelled.snapshot)
        await #expect(throws: FocusReminderCollectionStore.StoreError.staleOutbox) {
            try await store.acknowledge(outboxID: event.id)
        }
        await #expect(throws: FocusReminderState.StateError.staleTicket) {
            try await store.apply(id: id,
                command: .update(.cancelSnooze(ticketID: snooze.id)), at: snooze.deadline)
        }
    }
}

@Test func reminderSnoozeCancelWriteFailuresPreservePendingAndQueuedIntent() async throws {
    enum Failure: Error { case denied }
    try await withCancellationFile { file in
        let store = FocusReminderCollectionStore(fileURL: file)
        let (id, _, snooze) = try await prepareCancellationSnooze(store)
        let failing = FocusReminderCollectionStore(fileURL: file,
            read: { try Data(contentsOf: $0) }, write: { _, _ in throw Failure.denied })
        let pendingBytes = try Data(contentsOf: file)
        await #expect(throws: Failure.denied) {
            try await failing.apply(id: id,
                command: .update(.cancelSnooze(ticketID: snooze.id)), at: cancelDue)
        }
        #expect(try Data(contentsOf: file) == pendingBytes)
        #expect(try await store.load().entries.first?.state.pendingSnooze == snooze)
        let claimed = try await store.apply(id: id,
            command: .update(.claimSnooze(ticketID: snooze.id)), at: snooze.deadline)
        let intent = try #require(claimed.enqueued)
        let queuedBytes = try Data(contentsOf: file)
        await #expect(throws: Failure.denied) {
            try await failing.apply(id: id,
                command: .update(.cancelSnooze(ticketID: snooze.id)), at: snooze.deadline)
        }
        #expect(try Data(contentsOf: file) == queuedBytes)
        #expect(try await store.load().outbox == [intent])
    }
}

@Test func reminderSingleStoreCanCancelPendingSnoozeWithoutReopeningOccurrence() async throws {
    try await withCancellationFile { file in
        let schedule = try FocusReminderSchedule(rule: .once(cancelDue))
        let store = FocusReminderStore(fileURL: file)
        _ = try await store.create(schedule: schedule)
        _ = try await store.apply(id: schedule.id, command: .setEnabled(true), at: cancelStart)
        let planned = try await store.apply(id: schedule.id,
            command: .replan(cancelCalendar), at: cancelStart)
        let original = try #require(planned.state.pending)
        _ = try await store.apply(id: schedule.id,
            command: .claim(ticketID: original.id, calendar: cancelCalendar), at: cancelDue)
        let delayed = try await store.apply(id: schedule.id,
            command: .snooze(sourceTicketID: original.id, seconds: 300), at: cancelDue)
        let pending = try #require(delayed.state.pendingSnooze)
        let restored = FocusReminderStore(fileURL: file)
        let cancelled = try await restored.apply(id: schedule.id,
            command: .cancelSnooze(ticketID: pending.id), at: cancelDue)
        #expect(cancelled.state.pendingSnooze == nil)
        #expect(cancelled.state.lastObserved == original.occurrence)
        await #expect(throws: FocusReminderState.StateError.staleTicket) {
            try await restored.apply(id: schedule.id,
                command: .cancelSnooze(ticketID: pending.id), at: cancelDue)
        }
        await #expect(throws: FocusReminderState.StateError.staleTicket) {
            try await restored.apply(id: schedule.id,
                command: .snooze(sourceTicketID: original.id, seconds: 300), at: cancelDue)
        }
    }
}

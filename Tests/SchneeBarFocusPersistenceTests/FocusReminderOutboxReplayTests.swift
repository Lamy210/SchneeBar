import Foundation
import SchneeBarFocusCore
@testable import SchneeBarFocusPersistence
import Testing

private let replayStart = Date(timeIntervalSince1970: 1_700_000_000)
private let replayCalendar = Calendar(identifier: .gregorian)

private func withReplayStore(_ body: (FocusReminderCollectionStore) async throws -> Void) async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false,
                                           attributes: [.posixPermissions: 0o700])
    defer { try? FileManager.default.removeItem(at: directory) }
    try await body(FocusReminderCollectionStore(fileURL: directory.appendingPathComponent("reminders.json")))
}

private func claimReplayReminder(
    _ store: FocusReminderCollectionStore, due: Date, claimedAt: Date
) async throws -> FocusReminderOutboxRecord {
    let entry = try await store.add(title: "Replay", rule: .once(due))
    _ = try await store.apply(id: entry.id, command: .update(.setEnabled(true)), at: replayStart)
    let planned = try await store.apply(id: entry.id, command: .update(.replan(replayCalendar)), at: replayStart)
    let ticket = try #require(planned.snapshot.entries.first(where: { $0.id == entry.id })?.state.pending)
    let consumed = try await store.apply(id: entry.id,
        command: .update(.claim(ticketID: ticket.id, calendar: replayCalendar)), at: claimedAt)
    return try #require(consumed.enqueued)
}

@Test func outboxReplayPlanSeparatesMissedClockHeldAndBoundedReady() async throws {
    try await withReplayStore { store in
        let firstDue = replayStart.addingTimeInterval(60)
        let secondDue = replayStart.addingTimeInterval(120)
        let thirdDue = replayStart.addingTimeInterval(180)
        let first = try await claimReplayReminder(store, due: firstDue, claimedAt: firstDue)
        let second = try await claimReplayReminder(store, due: secondDue, claimedAt: secondDue)
        let third = try await claimReplayReminder(store, due: thirdDue, claimedAt: thirdDue)
        let snapshot = try await store.load()
        let now = thirdDue
        let plan = try snapshot.outboxReplayPlan(at: now, maxBatchSize: 1, maxLateness: 100)
        #expect(plan.needsRecovery == [first])
        #expect(plan.ready == [second])
        #expect(plan.heldForClock.isEmpty)
        #expect(plan.deferredReadyCount == 1)
        #expect(try snapshot.outboxReplayPlan(at: now, maxBatchSize: 2, maxLateness: 100).ready
                == [second, third])
        #expect(try await store.load() == snapshot)
        let earlier = try snapshot.outboxReplayPlan(at: firstDue.addingTimeInterval(-1))
        #expect(earlier.ready.isEmpty)
        #expect(earlier.heldForClock.count == 3)
        #expect(earlier.needsRecovery.isEmpty)
        #expect(earlier.deferredReadyCount == 0)
        // Exact cutoff is accepted; beyond cutoff requires explicit recovery.
        let boundary = try snapshot.outboxReplayPlan(at: firstDue.addingTimeInterval(100), maxLateness: 100)
        #expect(boundary.ready.contains(first))
        let beyond = try snapshot.outboxReplayPlan(at: firstDue.addingTimeInterval(101), maxLateness: 100)
        #expect(beyond.needsRecovery.contains(first))
    }
}

@Test func outboxReplayPlanHoldsAfterClockRollbackPastOriginalDeadline() async throws {
    try await withReplayStore { store in
        let due = replayStart.addingTimeInterval(60)
        let claimed = due.addingTimeInterval(90)
        let event = try await claimReplayReminder(store, due: due, claimedAt: claimed)
        let snapshot = try await store.load()
        let beforeClaim = try snapshot.outboxReplayPlan(at: due.addingTimeInterval(20),
            maxLateness: 200)
        #expect(beforeClaim.heldForClock == [event])
        #expect(beforeClaim.ready.isEmpty && beforeClaim.needsRecovery.isEmpty)
        let eligible = try snapshot.outboxReplayPlan(at: claimed, maxLateness: 90)
        #expect(eligible.ready == [event])
        let late = try snapshot.outboxReplayPlan(at: claimed, maxLateness: 89)
        #expect(late.needsRecovery == [event])
    }
}

@Test func outboxReplayPlanRegularPrecedesSnoozeAtSameDeadlineAndReactsToDisable() async throws {
    try await withReplayStore { store in
        let initial = replayStart.addingTimeInterval(60)
        let later = initial.addingTimeInterval(60)
        let a = try await store.add(title: "A", rule: .once(initial))
        let b = try await store.add(title: "B", rule: .once(later))
        for entry in [a, b] {
            _ = try await store.apply(id: entry.id, command: .update(.setEnabled(true)), at: replayStart)
            _ = try await store.apply(id: entry.id, command: .update(.replan(replayCalendar)), at: replayStart)
        }
        let snapshot = try await store.load()
        let aTicket = try #require(snapshot.entries.first(where: { $0.id == a.id })?.state.pending)
        let bTicket = try #require(snapshot.entries.first(where: { $0.id == b.id })?.state.pending)
        _ = try await store.apply(id: a.id,
            command: .update(.claim(ticketID: aTicket.id, calendar: replayCalendar)), at: initial)
        _ = try await store.apply(id: a.id,
            command: .update(.snooze(sourceTicketID: aTicket.id, seconds: 60)), at: initial)
        let delayed = try #require(try await store.load().entries.first(where: { $0.id == a.id })?.state.pendingSnooze)
        _ = try await store.apply(id: a.id,
            command: .update(.claimSnooze(ticketID: delayed.id)), at: later)
        _ = try await store.apply(id: b.id,
            command: .update(.claim(ticketID: bTicket.id, calendar: replayCalendar)), at: later)
        let queued = try await store.load()
        let plan = try queued.outboxReplayPlan(at: later)
        #expect(plan.ready.count == 2)
        #expect(plan.ready.map(\.kind) == [.regular, .snooze])
        #expect(plan.ready.map(\.reminderID) == [b.id, a.id])
        _ = try await store.apply(id: a.id, command: .update(.setEnabled(false)), at: later)
        let afterDisable = try await store.load()
        #expect(try afterDisable.outboxReplayPlan(at: later).ready.map(\.reminderID) == [b.id])
        let record = try #require(afterDisable.outbox.first)
        _ = try await store.acknowledge(outboxID: record.id)
        #expect(try await store.load().outboxReplayPlan(at: later).isEmpty)
    }
}

@Test func outboxReplayPlanRejectsInvalidInputsWithoutMutation() async throws {
    try await withReplayStore { store in
        let snapshot = try await store.load()
        #expect(try snapshot.outboxReplayPlan(at: replayStart).isEmpty)
        #expect(throws: FocusReminderOutboxReplayPolicyError.invalidClock) {
            try snapshot.outboxReplayPlan(at: Date(timeIntervalSince1970: .infinity))
        }
        for limit in [0, -1, 129] {
            #expect(throws: FocusReminderOutboxReplayPolicyError.invalidBatchSize) {
                try snapshot.outboxReplayPlan(at: replayStart, maxBatchSize: limit)
            }
        }
        for lateness in [Double.nan, Double.infinity, -1, 86_401] {
            #expect(throws: FocusReminderOutboxReplayPolicyError.invalidLateness) {
                try snapshot.outboxReplayPlan(at: replayStart, maxLateness: lateness)
            }
        }
        #expect(try snapshot.outboxReplayPlan(at: replayStart, maxBatchSize: 128,
                                             maxLateness: 86_400).isEmpty)
    }
}

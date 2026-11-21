import Foundation
import SchneeBarFocusCore
@testable import SchneeBarFocusPersistence
import Testing

private let snoozeOrigin = Date(timeIntervalSince1970: 1_700_000_000)
private let snoozeDue = snoozeOrigin.addingTimeInterval(60)
private let snoozeCalendar = Calendar(identifier: .gregorian)

private func withSnoozeFile(_ body: (URL) async throws -> Void) async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false,
        attributes: [.posixPermissions: 0o700])
    defer { try? FileManager.default.removeItem(at: directory) }
    try await body(directory.appendingPathComponent("reminders.json"))
}

@Test func focusReminderSnoozeSurvivesRestartAndClaimsOnce() async throws {
    try await withSnoozeFile { file in
        let store = FocusReminderCollectionStore(fileURL: file)
        let entry = try await store.add(title: "A", rule: .once(snoozeDue))
        let id = entry.id
        _ = try await store.apply(id: id, command: .update(.setEnabled(true)), at: snoozeOrigin)
        let planned = try await store.apply(id: id, command: .update(.replan(snoozeCalendar)), at: snoozeOrigin)
        let ticket = try #require(planned.snapshot.entries.first?.state.pending)
        await #expect(throws: FocusReminderState.StateError.staleTicket) {
            try await store.apply(id: id, command: .update(.snooze(sourceTicketID: ticket.id, seconds: 300)), at: snoozeOrigin)
        }
        let claimed = try await store.apply(id: id, command: .update(.claim(ticketID: ticket.id, calendar: snoozeCalendar)), at: snoozeDue)
        #expect(claimed.claimed == ticket.occurrence && claimed.claimedSnooze == nil)
        let restored = FocusReminderCollectionStore(fileURL: file)
        let delayed = try await restored.apply(id: id, command: .update(.snooze(sourceTicketID: ticket.id, seconds: 300)), at: snoozeDue)
        let snooze = try #require(delayed.snapshot.entries.first?.state.pendingSnooze)
        #expect(snooze.deadline == snoozeDue.addingTimeInterval(300))
        #expect(snooze.id != ticket.id && snooze.occurrence == ticket.occurrence)
        #expect(delayed.snapshot.entries.first?.state.lastObserved == ticket.occurrence)
        let restarted = FocusReminderCollectionStore(fileURL: file)
        #expect(try await restarted.load() == delayed.snapshot)
        await #expect(throws: FocusReminderState.StateError.staleTicket) {
            try await restarted.apply(id: id, command: .update(.snooze(sourceTicketID: ticket.id, seconds: 300)), at: snoozeDue)
        }
        await #expect(throws: FocusReminderState.StateError.notDue) {
            try await restarted.apply(id: id, command: .update(.claimSnooze(ticketID: snooze.id)), at: snooze.deadline.addingTimeInterval(-1))
        }
        let result = try await restarted.apply(id: id, command: .update(.claimSnooze(ticketID: snooze.id)), at: snooze.deadline)
        #expect(result.claimed == nil && result.claimedSnooze == snooze)
        let state = try #require(result.snapshot.entries.first?.state)
        #expect(state.lastObserved == ticket.occurrence && state.pendingSnooze == nil && state.snoozeOpportunity == nil)
        await #expect(throws: FocusReminderState.StateError.staleTicket) {
            try await restarted.apply(id: id, command: .update(.claimSnooze(ticketID: snooze.id)), at: snooze.deadline)
        }
    }
}

@Test func focusReminderSnoozeKeepsRecurrenceAndNextClaimRevokesOldSnooze() throws {
    var state = FocusReminderState(schedule: try .init(rule: .daily(hour: 9, minute: 0)))
    try state.setEnabled(true)
    let firstPlan = try state.replan(at: snoozeOrigin, calendar: snoozeCalendar)
    let first = try #require(firstPlan)
    _ = try state.claim(ticketID: first.id, at: first.occurrence.date, calendar: snoozeCalendar)
    try state.snooze(sourceTicketID: first.id, seconds: 300, at: first.occurrence.date)
    let snooze = try #require(state.pendingSnooze)
    let nextPlan = try state.replan(at: first.occurrence.date, calendar: snoozeCalendar)
    let next = try #require(nextPlan)
    #expect(state.pendingSnooze == snooze && next.occurrence.date > snooze.deadline)
    _ = try state.claim(ticketID: next.id, at: next.occurrence.date, calendar: snoozeCalendar)
    #expect(state.pendingSnooze == nil && state.lastObserved == next.occurrence)
    #expect(throws: FocusReminderState.StateError.staleTicket) {
        try state.claimSnooze(ticketID: snooze.id, at: next.occurrence.date)
    }
    #expect(throws: FocusReminderState.StateError.staleTicket) {
        try state.snooze(sourceTicketID: first.id, seconds: 300, at: next.occurrence.date)
    }
}

@Test func focusReminderSnoozeValidatesActionWindowAndDisable() throws {
    var state = FocusReminderState(schedule: try .init(rule: .once(snoozeDue)))
    try state.setEnabled(true)
    let plan = try state.replan(at: snoozeOrigin, calendar: snoozeCalendar)
    let ticket = try #require(plan)
    _ = try state.claim(ticketID: ticket.id, at: snoozeDue, calendar: snoozeCalendar)
    let before = state
    for invalid: TimeInterval in [.nan, .infinity, 59, 3601] {
        #expect(throws: FocusReminderState.StateError.invalidSnoozeDuration) {
            try state.snooze(sourceTicketID: ticket.id, seconds: invalid, at: snoozeDue)
        }
    }
    for invalid in [snoozeDue.addingTimeInterval(-1), snoozeDue.addingTimeInterval(3601)] {
        #expect(throws: FocusReminderState.StateError.snoozeWindowExpired) {
            try state.snooze(sourceTicketID: ticket.id, seconds: 300, at: invalid)
        }
    }
    #expect(state == before)
    try state.snooze(sourceTicketID: ticket.id, seconds: 60, at: snoozeDue)
    let pending = try #require(state.pendingSnooze)
    try state.setEnabled(false)
    try state.setEnabled(true)
    #expect(state.pendingSnooze == nil && state.snoozeOpportunity == nil)
    #expect(state.lastObserved == ticket.occurrence)
    #expect(throws: FocusReminderState.StateError.staleTicket) {
        try state.claimSnooze(ticketID: pending.id, at: pending.deadline)
    }
    #expect(throws: FocusReminderState.StateError.staleTicket) {
        try state.snooze(sourceTicketID: ticket.id, seconds: 300, at: snoozeDue)
    }
}

@Test func focusReminderSnoozeFailedWritePreservesTicketAndEditRevokesIt() async throws {
    enum Failure: Error { case write }
    try await withSnoozeFile { file in
        let store = FocusReminderCollectionStore(fileURL: file)
        let entry = try await store.add(title: "A", rule: .once(snoozeDue))
        let id = entry.id
        _ = try await store.apply(id: id, command: .update(.setEnabled(true)), at: snoozeOrigin)
        let planned = try await store.apply(id: id, command: .update(.replan(snoozeCalendar)), at: snoozeOrigin)
        let ticket = try #require(planned.snapshot.entries.first?.state.pending)
        _ = try await store.apply(id: id, command: .update(.claim(ticketID: ticket.id, calendar: snoozeCalendar)), at: snoozeDue)
        let delayed = try await store.apply(id: id, command: .update(.snooze(sourceTicketID: ticket.id, seconds: 300)), at: snoozeDue)
        let snooze = try #require(delayed.snapshot.entries.first?.state.pendingSnooze)
        let bytes = try Data(contentsOf: file)
        let failing = FocusReminderCollectionStore(fileURL: file, read: { try Data(contentsOf: $0) }, write: { _, _ in throw Failure.write })
        await #expect(throws: Failure.write) {
            try await failing.apply(id: id, command: .update(.claimSnooze(ticketID: snooze.id)), at: snooze.deadline)
        }
        #expect(try Data(contentsOf: file) == bytes)
        #expect(try await store.load() == delayed.snapshot)
        let new = try await store.replaceRule(id: id, rule: .once(snooze.deadline.addingTimeInterval(60)), at: snooze.deadline, calendar: snoozeCalendar)
        #expect(new.state.pendingSnooze == nil && new.state.snoozeOpportunity == nil)
        await #expect(throws: FocusReminderCollectionStore.StoreError.staleReminder) {
            try await store.apply(id: id, command: .update(.claimSnooze(ticketID: snooze.id)), at: snooze.deadline)
        }
    }
}

@Test func focusReminderSnoozeReadsVersionOneAndRejectsInvalidVersionTwo() throws {
    var state = FocusReminderState(schedule: try .init(rule: .once(snoozeDue)))
    try state.setEnabled(true)
    let plan = try state.replan(at: snoozeOrigin, calendar: snoozeCalendar)
    let ticket = try #require(plan)
    var old = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(state)) as? [String: Any])
    old["version"] = 1
    let restored = try JSONDecoder().decode(FocusReminderState.self, from: JSONSerialization.data(withJSONObject: old))
    #expect(restored == state && restored.snoozeOpportunity == nil)
    _ = try state.claim(ticketID: ticket.id, at: snoozeDue, calendar: snoozeCalendar)
    try state.snooze(sourceTicketID: ticket.id, seconds: 300, at: snoozeDue)
    let data = try JSONEncoder().encode(state)
    #expect(try JSONDecoder().decode(FocusReminderState.self, from: data) == state)
    var invalid = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    invalid["enabled"] = false
    #expect(throws: FocusReminderState.StateError.invalidRecord) {
        try JSONDecoder().decode(FocusReminderState.self, from: JSONSerialization.data(withJSONObject: invalid))
    }
    invalid["enabled"] = true
    invalid["version"] = 1
    #expect(throws: FocusReminderState.StateError.invalidRecord) {
        try JSONDecoder().decode(FocusReminderState.self, from: JSONSerialization.data(withJSONObject: invalid))
    }
    invalid["version"] = 3
    #expect(throws: FocusReminderState.StateError.unsupportedVersion) {
        try JSONDecoder().decode(FocusReminderState.self, from: JSONSerialization.data(withJSONObject: invalid))
    }
}

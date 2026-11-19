import Foundation
import SchneeBarFocusCore
@testable import SchneeBarFocusPersistence
import Testing

private func clock(_ value: String) throws -> Date { try #require(ISO8601DateFormatter().date(from: value)) }
private func cal(_ zone: String) throws -> Calendar {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = try #require(TimeZone(identifier: zone))
    return calendar
}
private func withReminderFile(_ action: (URL) async throws -> Void) async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false,
        attributes: [.posixPermissions: 0o700])
    defer { try? FileManager.default.removeItem(at: directory) }
    try await action(directory.appendingPathComponent("reminder-v1.json"))
}

@Test func focusReminderStorePersistsClaimAndPreventsReplayAfterTravel() async throws {
    try await withReminderFile { file in
        let schedule = try FocusReminderSchedule(rule: .daily(hour: 9, minute: 0))
        let store = FocusReminderStore(fileURL: file)
        let tokyo = try cal("Asia/Tokyo"), ny = try cal("America/New_York")
        let now = try clock("2026-11-19T23:00:00Z")
        let created = try await store.create(schedule: schedule)
        #expect(!created.enabled && created.pending == nil)
        _ = try await store.apply(id: schedule.id, command: .setEnabled(true), at: now)
        let plan = try await store.apply(id: schedule.id, command: .replan(tokyo), at: now)
        let ticket = try #require(plan.state.pending)
        let restored = FocusReminderStore(fileURL: file)
        #expect(try await restored.load() == plan.state)
        let repeatPlan = try await restored.apply(id: schedule.id, command: .replan(tokyo), at: now)
        #expect(repeatPlan.state.pending == ticket)
        let claim = try await restored.apply(id: schedule.id, command: .claim(ticketID: ticket.id, calendar: tokyo), at: ticket.occurrence.date)
        #expect(claim.claimed == ticket.occurrence && claim.state.pending == nil)
        let restarted = FocusReminderStore(fileURL: file)
        #expect(try await restarted.load() == claim.state)
        await #expect(throws: FocusReminderState.StateError.staleTicket) {
            try await restarted.apply(id: schedule.id, command: .claim(ticketID: ticket.id, calendar: tokyo), at: ticket.occurrence.date)
        }
        let next = try await restarted.apply(id: schedule.id, command: .replan(ny), at: now)
        #expect(next.state.pending?.occurrence.date == (try clock("2026-11-21T14:00:00Z")))
    }
}

@Test func focusReminderStoreRevokesChangedAndDisabledTickets() async throws {
    try await withReminderFile { file in
        let store = FocusReminderStore(fileURL: file)
        let schedule = try FocusReminderSchedule(rule: .daily(hour: 9, minute: 0))
        let tokyo = try cal("Asia/Tokyo"), ny = try cal("America/New_York")
        let now = try clock("2026-11-19T23:00:00Z")
        _ = try await store.create(schedule: schedule)
        _ = try await store.apply(id: schedule.id, command: .setEnabled(true), at: now)
        let old = try await store.apply(id: schedule.id, command: .replan(tokyo), at: now)
        let ticket = try #require(old.state.pending)
        await #expect(throws: FocusReminderState.StateError.notDue) {
            try await store.apply(id: schedule.id, command: .claim(ticketID: ticket.id, calendar: tokyo), at: now)
        }
        await #expect(throws: FocusReminderState.StateError.staleTicket) {
            try await store.apply(id: schedule.id, command: .claim(ticketID: ticket.id, calendar: ny), at: ticket.occurrence.date)
        }
        let replanned = try await store.apply(id: schedule.id, command: .replan(ny), at: now)
        let next = try #require(replanned.state.pending)
        #expect(next.id != ticket.id)
        _ = try await store.apply(id: schedule.id, command: .setEnabled(false), at: now)
        _ = try await store.apply(id: schedule.id, command: .setEnabled(true), at: now)
        let renewed = try await store.apply(id: schedule.id, command: .replan(ny), at: now)
        #expect(renewed.state.pending?.id != next.id)
        await #expect(throws: FocusReminderState.StateError.staleTicket) {
            try await store.apply(id: schedule.id, command: .claim(ticketID: next.id, calendar: ny), at: next.occurrence.date)
        }
        #expect(try await store.load() == renewed.state)
    }
}

@Test func focusReminderStoreRejectsImportedActivationAndInvalidRecord() async throws {
    try await withReminderFile { file in
        let store = FocusReminderStore(fileURL: file)
        let schedule = try FocusReminderSchedule(rule: .daily(hour: 9, minute: 0))
        let now = try clock("2026-11-19T23:00:00Z"), tokyo = try cal("Asia/Tokyo")
        _ = try await store.create(schedule: schedule, origin: .imported)
        let original = try Data(contentsOf: file)
        await #expect(throws: FocusReminderState.StateError.importedInactive) {
            try await store.apply(id: schedule.id, command: .setEnabled(true), at: now)
        }
        let inactive = try await store.apply(id: schedule.id, command: .replan(tokyo), at: now)
        #expect(inactive.state.pending == nil && !inactive.state.enabled)
        #expect(try Data(contentsOf: file) == original)
        var json = try #require(JSONSerialization.jsonObject(with: original) as? [String: Any])
        json["enabled"] = true
        let invalid = try JSONSerialization.data(withJSONObject: json)
        try invalid.write(to: file, options: .atomic)
        await #expect(throws: FocusReminderState.StateError.invalidRecord) { try await store.load() }
        #expect(try Data(contentsOf: file) == invalid)
    }
}

@Test func focusReminderStoreFailureAndConcurrentClaimsAreCommitFenced() async throws {
    enum Failure: Error { case write }
    try await withReminderFile { file in
        let store = FocusReminderStore(fileURL: file)
        let now = try clock("2026-11-20T00:00:00Z"), tokyo = try cal("Asia/Tokyo")
        let date = now.addingTimeInterval(60)
        let schedule = try FocusReminderSchedule(rule: .once(date))
        _ = try await store.create(schedule: schedule)
        _ = try await store.apply(id: schedule.id, command: .setEnabled(true), at: now)
        let plan = try await store.apply(id: schedule.id, command: .replan(tokyo), at: now)
        let ticket = try #require(plan.state.pending)
        let bytes = try Data(contentsOf: file)
        let failing = FocusReminderStore(fileURL: file, read: { try Data(contentsOf: $0) }, write: { _, _ in throw Failure.write })
        await #expect(throws: Failure.write) {
            try await failing.apply(id: schedule.id, command: .claim(ticketID: ticket.id, calendar: tokyo), at: date)
        }
        #expect(try Data(contentsOf: file) == bytes)
        let count = try await withThrowingTaskGroup(of: Bool.self) { group in
            for _ in 0..<16 {
                group.addTask {
                    do { return try await store.apply(id: schedule.id, command: .claim(ticketID: ticket.id, calendar: tokyo), at: date).claimed != nil }
                    catch FocusReminderState.StateError.staleTicket { return false }
                }
            }
            var count = 0
            for try await claimed in group { if claimed { count += 1 } }
            return count
        }
        #expect(count == 1)
        let restarted = FocusReminderStore(fileURL: file)
        let next = try await restarted.apply(id: schedule.id, command: .replan(tokyo), at: now)
        #expect(next.state.pending == nil && next.state.lastObserved == ticket.occurrence)
    }
}

import Foundation
import SchneeBarFocusCore
import Testing

private let historyOrigin = Date(timeIntervalSince1970: 1_700_000_000)

private func completedCountdown(id: UUID = UUID(), at start: Date, duration: TimeInterval = 10) throws -> FocusCountdown {
    var value = try FocusCountdown(id: id, duration: duration, now: start)
    _ = try value.reconcile(at: start.addingTimeInterval(duration + 100))
    return value
}

@Test func focusHistoryRecordsOnlyCompletedNativePhasesAndUsesDeadline() throws {
    var history = FocusHistory()
    var timer = try FocusCountdown(duration: 10, now: historyOrigin)
    #expect(try history.record(completed: timer) == .incomplete)
    _ = try timer.pause(at: historyOrigin)
    #expect(try history.record(completed: timer) == .incomplete)
    _ = try timer.cancel(at: historyOrigin)
    #expect(try history.record(completed: timer) == .incomplete)
    let completed = try completedCountdown(at: historyOrigin)
    #expect(try history.record(completed: completed) == .retained)
    #expect(try history.record(completed: completed) == .duplicate)
    let entry = try #require(history.entries.first)
    #expect(entry.sourceID == completed.id && entry.countdownID == completed.id && entry.step == nil)
    #expect(entry.kind == .countdown && entry.plannedDuration == 10)
    #expect(entry.deadline == historyOrigin.addingTimeInterval(10))
    #expect(history.entries.count == 1)
}

@Test func focusHistoryTracksPomodoroPhasesIndependentlyAcrossRestore() throws {
    let plan = try FocusPomodoro.Plan(rounds: 3, focus: 10, shortBreak: 5, longBreak: 7, longBreakEvery: 2)
    var session = try FocusPomodoro(plan: plan, now: historyOrigin)
    var history = FocusHistory()
    let kinds: [FocusHistory.Kind] = [.focus, .shortBreak, .focus, .longBreak, .focus]
    var now = historyOrigin
    for step in kinds.indices {
        #expect(try history.record(completed: session) == .incomplete)
        now = now.addingTimeInterval(session.countdown.duration)
        _ = try session.reconcile(at: now)
        #expect(try history.record(completed: session) == .retained)
        let data = try JSONEncoder().encode(history)
        history = try JSONDecoder().decode(FocusHistory.self, from: data)
        #expect(try history.record(completed: session) == .duplicate)
        let entry = try #require(history.entries.first)
        #expect(entry.sourceID == session.id && entry.step == step && entry.kind == kinds[step])
        #expect(entry.countdownID == session.countdown.id && entry.deadline == now)
        if step < kinds.count - 1 { try session.advance(step: step, at: now) }
    }
    #expect(history.entries.count == 5 && session.isFinished)
    #expect(history.entries.compactMap(\.step) == [4, 3, 2, 1, 0])
}

@Test func focusHistoryRejectsConflictingRetainedIdentityWithoutMutation() throws {
    let id = UUID()
    let first = try completedCountdown(id: id, at: historyOrigin)
    let different = try completedCountdown(id: id, at: historyOrigin.addingTimeInterval(1))
    var history = FocusHistory()
    _ = try history.record(completed: first)
    let old = history
    #expect(throws: FocusHistory.ValidationError.conflictingIdentity) {
        try history.record(completed: different)
    }
    #expect(history == old)
}

@Test func focusHistoryKeepsNewest500AndDeterministicTies() throws {
    var history = FocusHistory()
    let oldest = try completedCountdown(at: historyOrigin)
    _ = try history.record(completed: oldest)
    for offset in 1...500 {
        _ = try history.record(completed: completedCountdown(at: historyOrigin.addingTimeInterval(Double(offset))))
    }
    #expect(history.entries.count == 500)
    #expect(history.entries.last?.deadline == historyOrigin.addingTimeInterval(11))
    let full = history
    #expect(try history.record(completed: oldest) == .outsideRetention)
    #expect(history == full)
    let a = try completedCountdown(id: #require(UUID(uuidString: "00000000-0000-0000-0000-000000000001")), at: historyOrigin)
    let b = try completedCountdown(id: #require(UUID(uuidString: "00000000-0000-0000-0000-000000000002")), at: historyOrigin)
    var forward = FocusHistory(), reverse = FocusHistory()
    _ = try forward.record(completed: a)
    _ = try forward.record(completed: b)
    _ = try reverse.record(completed: b)
    _ = try reverse.record(completed: a)
    #expect(forward == reverse && forward.entries.map(\.sourceID) == [a.id, b.id])
}

@Test func focusHistoryRejectsInvalidVersionDuplicateOversizeAndEntryShape() throws {
    var history = FocusHistory()
    _ = try history.record(completed: completedCountdown(at: historyOrigin))
    let encoded = try JSONEncoder().encode(history)
    var json = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
    let original = try #require((json["entries"] as? [[String: Any]])?.first)
    json["version"] = 2
    #expect(throws: FocusHistory.ValidationError.unsupportedVersion) {
        try JSONDecoder().decode(FocusHistory.self, from: JSONSerialization.data(withJSONObject: json))
    }
    json["version"] = 1
    json["entries"] = [original, original]
    #expect(throws: FocusHistory.ValidationError.duplicateIdentity) {
        try JSONDecoder().decode(FocusHistory.self, from: JSONSerialization.data(withJSONObject: json))
    }
    json["entries"] = Array(repeating: original, count: 501)
    #expect(throws: FocusHistory.ValidationError.tooManyEntries) {
        try JSONDecoder().decode(FocusHistory.self, from: JSONSerialization.data(withJSONObject: json))
    }
    var invalid = original
    invalid["step"] = Int.max
    json["entries"] = [invalid]
    #expect(throws: FocusHistory.ValidationError.invalidEntry) {
        try JSONDecoder().decode(FocusHistory.self, from: JSONSerialization.data(withJSONObject: json))
    }
    invalid = original
    invalid["plannedDuration"] = 0
    json["entries"] = [invalid]
    #expect(throws: FocusHistory.ValidationError.invalidEntry) {
        try JSONDecoder().decode(FocusHistory.self, from: JSONSerialization.data(withJSONObject: json))
    }
}

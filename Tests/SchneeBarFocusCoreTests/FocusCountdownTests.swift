import Foundation
import SchneeBarFocusCore
import Testing

private let origin = Date(timeIntervalSince1970: 1_700_000_000)

@Test func focusCountdownReconcilesSleepAndDecodedCompletionOnce() throws {
    let original = try FocusCountdown(duration: 60, now: origin)
    let data = try JSONEncoder().encode(original)
    var restored = try JSONDecoder().decode(FocusCountdown.self, from: data)
    let wake = origin.addingTimeInterval(600)
    #expect(try restored.remaining(at: wake) == 0)
    #expect(restored == original)
    let completion = try #require(restored.reconcile(at: wake))
    #expect(completion.countdownID == original.id)
    #expect(completion.deadline == origin.addingTimeInterval(60))
    #expect(try restored.reconcile(at: wake) == nil)
    let completedData = try JSONEncoder().encode(restored)
    var restarted = try JSONDecoder().decode(FocusCountdown.self, from: completedData)
    #expect(try restarted.reconcile(at: wake.addingTimeInterval(3_600)) == nil)
    #expect(restarted.phase == .completed(deadline: completion.deadline))
}

@Test func focusCountdownPausesWithoutCountingPausedTime() throws {
    var timer = try FocusCountdown(duration: 120, now: origin)
    #expect(try timer.pause(at: origin.addingTimeInterval(30)) == nil)
    #expect(timer.phase == .paused(remaining: 90))
    let resume = origin.addingTimeInterval(3_600)
    let data = try JSONEncoder().encode(timer)
    timer = try JSONDecoder().decode(FocusCountdown.self, from: data)
    #expect(try timer.remaining(at: resume) == 90)
    #expect(try timer.reconcile(at: resume) == nil)
    try timer.resume(at: resume)
    let deadline = resume.addingTimeInterval(90)
    #expect(timer.phase == .running(deadline: deadline))
    try timer.resume(at: resume.addingTimeInterval(20))
    #expect(timer.phase == .running(deadline: deadline))
    #expect(try timer.reconcile(at: deadline) != nil)
}

@Test func focusCountdownExpiryWinsOverLateCommands() throws {
    var timer = try FocusCountdown(duration: 10, now: origin)
    let end = origin.addingTimeInterval(10)
    #expect(try timer.pause(at: end) != nil)
    #expect(timer.phase == .completed(deadline: end))
    #expect(try timer.cancel(at: end) == nil)
    try timer.resume(at: end)
    #expect(timer.phase == .completed(deadline: end))
    var lateCancel = try FocusCountdown(duration: 10, now: origin)
    #expect(try lateCancel.cancel(at: end) != nil)
    #expect(lateCancel.phase == .completed(deadline: end))
}

@Test func focusCountdownCancelledStateNeverCompletesOrResumes() throws {
    var timer = try FocusCountdown(duration: 10, now: origin)
    #expect(try timer.cancel(at: origin.addingTimeInterval(5)) == nil)
    let end = origin.addingTimeInterval(100)
    try timer.resume(at: end)
    #expect(try timer.reconcile(at: end) == nil)
    #expect(try timer.remaining(at: end) == 0 && timer.phase == .cancelled)
}

@Test func focusCountdownRejectsInvalidDurationClockAndVersion() throws {
    for invalid in [0, -1, .infinity, .nan, FocusCountdown.maximumDuration + 1] {
        #expect(throws: FocusCountdown.ValidationError.invalidDuration) {
            try FocusCountdown(duration: invalid, now: origin)
        }
    }
    var timer = try FocusCountdown(duration: 60, now: origin)
    let snapshot = timer
    #expect(throws: FocusCountdown.ValidationError.invalidClock) {
        try timer.reconcile(at: Date(timeIntervalSince1970: .nan))
    }
    #expect(timer == snapshot)
    let data = try JSONEncoder().encode(timer)
    var json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    json["version"] = 2
    #expect(throws: FocusCountdown.ValidationError.unsupportedVersion) {
        try JSONDecoder().decode(FocusCountdown.self, from: JSONSerialization.data(withJSONObject: json))
    }
    json["version"] = 1
    json["duration"] = 0
    #expect(throws: FocusCountdown.ValidationError.invalidRecord) {
        try JSONDecoder().decode(FocusCountdown.self, from: JSONSerialization.data(withJSONObject: json))
    }
}

@Test func focusCountdownRejectsImpossiblePausedRecordAndClampsClockRollback() throws {
    var timer = try FocusCountdown(duration: 60, now: origin)
    let earlier = origin.addingTimeInterval(-600)
    #expect(try timer.remaining(at: earlier) == 60)
    #expect(try timer.pause(at: earlier) == nil)
    #expect(timer.phase == .paused(remaining: 60))
    let data = try JSONEncoder().encode(timer)
    var json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    json["duration"] = 30
    #expect(throws: FocusCountdown.ValidationError.invalidRecord) {
        try JSONDecoder().decode(FocusCountdown.self, from: JSONSerialization.data(withJSONObject: json))
    }
}

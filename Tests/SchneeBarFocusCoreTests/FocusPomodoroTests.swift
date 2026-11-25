import Foundation
import SchneeBarFocusCore
import Testing

private let epoch = Date(timeIntervalSince1970: 1_700_000_000)

@Test func focusPomodoroUsesExplicitNextPhaseAndLongBreakCadence() throws {
    let plan = try FocusPomodoro.Plan(rounds: 3, focus: 60, shortBreak: 10, longBreak: 20, longBreakEvery: 2)
    var session = try FocusPomodoro(plan: plan, now: epoch)
    let kinds: [FocusPomodoro.Kind] = [.focus, .shortBreak, .focus, .longBreak, .focus]
    let durations: [TimeInterval] = [60, 10, 60, 20, 60]
    var now = epoch
    for (index, duration) in durations.enumerated() {
        #expect(session.step == index && session.kind == kinds[index])
        #expect(session.round == index / 2 + 1)
        let deadline = now.addingTimeInterval(duration)
        #expect(session.countdown.phase == .running(deadline: deadline))
        #expect(try session.reconcile(at: deadline.addingTimeInterval(-1)) == nil)
        let completed = try session.reconcile(at: deadline)
        #expect(completed?.step == index && completed?.kind == kinds[index])
        #expect(completed?.finishesSession == (index == 4))
        #expect(try session.reconcile(at: deadline.addingTimeInterval(3600)) == nil)
        #expect(session.step == index)
        if index != 4 {
            let previousID = session.countdown.id
            now = deadline.addingTimeInterval(3600)
            try session.advance(step: index, at: now)
            #expect(session.countdown.id != previousID)
        }
    }
    #expect(session.isFinished && !session.canAdvance)
    #expect(throws: FocusPomodoro.ValidationError.sessionEnded) {
        try session.advance(step: 4, at: now)
    }
}

@Test func focusPomodoroRestoresPausedPhaseWithoutCountingSleep() throws {
    var session = try FocusPomodoro(plan: .init(), now: epoch)
    #expect(try session.pause(step: 0, at: epoch.addingTimeInterval(300)) == nil)
    let data = try JSONEncoder().encode(session)
    var restored = try JSONDecoder().decode(FocusPomodoro.self, from: data)
    #expect(restored == session)
    let wake = epoch.addingTimeInterval(18_000)
    #expect(try restored.reconcile(at: wake) == nil)
    #expect(restored.countdown.phase == .paused(remaining: 1200))
    try restored.resume(step: 0, at: wake)
    #expect(restored.countdown.phase == .running(deadline: wake.addingTimeInterval(1200)))
    let completed = try restored.reconcile(at: wake.addingTimeInterval(1200))
    #expect(completed?.sessionID == session.id && completed?.finishesSession == false)
    let waiting = try JSONEncoder().encode(restored)
    restored = try JSONDecoder().decode(FocusPomodoro.self, from: waiting)
    #expect(restored.canAdvance)
    #expect(try restored.reconcile(at: wake.addingTimeInterval(5000)) == nil)
}

@Test func focusPomodoroRejectsEarlyAndStalePhaseCommands() throws {
    var session = try FocusPomodoro(plan: .init(rounds: 2, focus: 10), now: epoch)
    let before = session
    #expect(throws: FocusPomodoro.ValidationError.phaseNotCompleted) {
        try session.advance(step: 0, at: epoch)
    }
    #expect(session == before)
    let wake = epoch.addingTimeInterval(100)
    _ = try session.reconcile(at: wake)
    try session.advance(step: 0, at: wake)
    let active = session
    #expect(throws: FocusPomodoro.ValidationError.stalePhase) {
        try session.pause(step: 0, at: wake)
    }
    #expect(throws: FocusPomodoro.ValidationError.stalePhase) {
        try session.cancel(step: 0, at: wake)
    }
    #expect(session == active)
    _ = try session.reconcile(at: wake.addingTimeInterval(300))
    let waiting = session
    #expect(throws: FocusPomodoro.ValidationError.stalePhase) {
        try session.advance(step: 0, at: wake.addingTimeInterval(300))
    }
    #expect(session == waiting && session.canAdvance)
}

@Test func focusPomodoroFinalExpiryWinsAndIntermediateCancelEndsSession() throws {
    var final = try FocusPomodoro(plan: .init(rounds: 1, focus: 10), now: epoch)
    let deadline = epoch.addingTimeInterval(10)
    let completed = try final.cancel(step: 0, at: deadline)
    #expect(completed?.finishesSession == true && final.isFinished && !final.isCancelled)
    var intermediate = try FocusPomodoro(plan: .init(rounds: 2, focus: 10), now: epoch)
    let elapsed = try intermediate.cancel(step: 0, at: deadline)
    #expect(elapsed?.finishesSession == false && intermediate.isCancelled && !intermediate.canAdvance)
    #expect(try intermediate.reconcile(at: deadline.addingTimeInterval(100)) == nil)
    let restored = try JSONDecoder().decode(FocusPomodoro.self, from: JSONEncoder().encode(intermediate))
    #expect(restored == intermediate)
    var paused = try FocusPomodoro(plan: .init(), now: epoch)
    _ = try paused.pause(step: 0, at: epoch)
    #expect(try paused.cancel(step: 0, at: epoch) == nil)
    #expect(paused.isCancelled && paused.countdown.phase == .cancelled)
}

@Test func focusPomodoroValidatesPlanAndVersionedRecords() throws {
    for rounds in [0, 13, Int.max] {
        #expect(throws: FocusPomodoro.ValidationError.invalidPlan) {
            try FocusPomodoro.Plan(rounds: rounds)
        }
    }
    #expect(throws: FocusPomodoro.ValidationError.invalidPlan) {
        try FocusPomodoro.Plan(focus: .nan)
    }
    #expect(throws: FocusPomodoro.ValidationError.invalidPlan) {
        try FocusPomodoro.Plan(longBreakEvery: 0)
    }
    let session = try FocusPomodoro(plan: .init(), now: epoch)
    let data = try JSONEncoder().encode(session)
    var record = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    record["version"] = 2
    #expect(throws: FocusPomodoro.ValidationError.unsupportedVersion) {
        try JSONDecoder().decode(FocusPomodoro.self, from: JSONSerialization.data(withJSONObject: record))
    }
    record["version"] = 1
    record["step"] = Int.max
    #expect(throws: FocusPomodoro.ValidationError.invalidRecord) {
        try JSONDecoder().decode(FocusPomodoro.self, from: JSONSerialization.data(withJSONObject: record))
    }
    record["step"] = 1
    #expect(throws: FocusPomodoro.ValidationError.invalidRecord) {
        try JSONDecoder().decode(FocusPomodoro.self, from: JSONSerialization.data(withJSONObject: record))
    }
    record["step"] = 0
    record["isCancelled"] = true
    #expect(throws: FocusPomodoro.ValidationError.invalidRecord) {
        try JSONDecoder().decode(FocusPomodoro.self, from: JSONSerialization.data(withJSONObject: record))
    }
}

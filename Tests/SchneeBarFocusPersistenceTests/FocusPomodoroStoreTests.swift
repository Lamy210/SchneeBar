import Foundation
import SchneeBarFocusCore
@testable import SchneeBarFocusPersistence
import Testing

private let epoch = Date(timeIntervalSince1970: 1_700_000_000)

private func withPomodoroFile(_ body: (URL) async throws -> Void) async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false,
        attributes: [.posixPermissions: 0o700])
    defer { try? FileManager.default.removeItem(at: directory) }
    try await body(directory.appendingPathComponent("pomodoro-v1.json"))
}

@Test func focusPomodoroStoreRestoresWaitingAndRejectsStaleReconcile() async throws {
    try await withPomodoroFile { file in
        let id = UUID()
        let plan = try FocusPomodoro.Plan(rounds: 2, focus: 10, shortBreak: 5)
        let store = FocusPomodoroStore(fileURL: file)
        _ = try await store.apply(.start(id: id, plan: plan), at: epoch)
        let wake = epoch.addingTimeInterval(3600)
        let completed = try await store.apply(.phase(id: id, step: 0, action: .reconcile), at: wake)
        #expect(completed.completion?.step == 0 && completed.session.canAdvance)
        let restored = FocusPomodoroStore(fileURL: file)
        #expect(try await restored.load() == completed.session)
        let replay = try await restored.apply(.phase(id: id, step: 0, action: .reconcile), at: wake)
        #expect(replay.completion == nil)
        do {
            _ = try await restored.apply(.start(id: UUID(), plan: plan), at: wake)
            Issue.record("Waiting session must not be replaced")
        } catch { #expect(error as? FocusPomodoroStore.StoreError == .activeSession) }
        let advanced = try await restored.apply(.phase(id: id, step: 0, action: .advance), at: wake)
        #expect(advanced.session.countdown.phase == .running(deadline: wake.addingTimeInterval(5)))
        let before = try Data(contentsOf: file)
        do {
            _ = try await restored.apply(.phase(id: id, step: 0, action: .reconcile), at: wake.addingTimeInterval(10))
            Issue.record("Stale observation must not complete successor")
        } catch { #expect(error as? FocusPomodoroStore.StoreError == .stalePhase) }
        #expect(try Data(contentsOf: file) == before)
        #expect(try await restored.load() == advanced.session)
    }
}

@Test func focusPomodoroStoreConcurrentCompletionReturnsOneEvent() async throws {
    try await withPomodoroFile { file in
        let id = UUID(), plan = try FocusPomodoro.Plan(rounds: 1, focus: 10)
        let store = FocusPomodoroStore(fileURL: file)
        _ = try await store.apply(.start(id: id, plan: plan), at: epoch)
        let end = epoch.addingTimeInterval(10)
        let count = try await withThrowingTaskGroup(of: FocusPomodoroStore.Result.self) { group in
            for _ in 0..<16 {
                group.addTask { try await store.apply(.phase(id: id, step: 0, action: .reconcile), at: end) }
            }
            var count = 0
            for try await result in group {
                #expect(result.session.isFinished)
                if let completion = result.completion {
                    #expect(completion.finishesSession && completion.sessionID == id)
                    count += 1
                }
            }
            return count
        }
        #expect(count == 1)
        let restored = FocusPomodoroStore(fileURL: file)
        let replay = try await restored.apply(.phase(id: id, step: 0, action: .reconcile), at: end)
        #expect(replay.session.isFinished && replay.completion == nil)
    }
}

@Test func focusPomodoroStoreFailedWritePreservesPhaseAndRetry() async throws {
    enum Failure: Error { case write }
    try await withPomodoroFile { file in
        let id = UUID(), plan = try FocusPomodoro.Plan(rounds: 2, focus: 10)
        let store = FocusPomodoroStore(fileURL: file)
        let started = try await store.apply(.start(id: id, plan: plan), at: epoch)
        let original = try Data(contentsOf: file)
        let failing = FocusPomodoroStore(fileURL: file, read: { try Data(contentsOf: $0) },
            write: { _, _ in throw Failure.write })
        let end = epoch.addingTimeInterval(10)
        do {
            _ = try await failing.apply(.phase(id: id, step: 0, action: .reconcile), at: end)
            Issue.record("Uncommitted completion must not escape")
        } catch { #expect(error as? Failure == .write) }
        #expect(try Data(contentsOf: file) == original)
        #expect(try await store.load() == started.session)
        let retry = try await store.apply(.phase(id: id, step: 0, action: .reconcile), at: end)
        #expect(retry.completion?.step == 0 && retry.session.canAdvance)
        let waiting = try Data(contentsOf: file)
        do {
            _ = try await failing.apply(.phase(id: id, step: 0, action: .advance), at: end)
            Issue.record("Failed advance must not publish successor")
        } catch { #expect(error as? Failure == .write) }
        #expect(try Data(contentsOf: file) == waiting)
        #expect(try await store.load() == retry.session)
    }
}

@Test func focusPomodoroStoreRestoresPauseAndRejectsPreviousSession() async throws {
    try await withPomodoroFile { file in
        let first = UUID(), second = UUID(), plan = try FocusPomodoro.Plan(rounds: 1, focus: 60)
        let store = FocusPomodoroStore(fileURL: file)
        _ = try await store.apply(.start(id: first, plan: plan), at: epoch)
        let paused = try await store.apply(.phase(id: first, step: 0, action: .pause), at: epoch.addingTimeInterval(10))
        let restored = FocusPomodoroStore(fileURL: file)
        #expect(try await restored.load() == paused.session)
        let wake = epoch.addingTimeInterval(3600)
        let resumed = try await restored.apply(.phase(id: first, step: 0, action: .resume), at: wake)
        #expect(resumed.session.countdown.phase == .running(deadline: wake.addingTimeInterval(50)))
        _ = try await restored.apply(.phase(id: first, step: 0, action: .cancel), at: wake)
        do {
            _ = try await restored.apply(.start(id: first, plan: plan), at: wake)
            Issue.record("Current session UUID must not be reused")
        } catch { #expect(error as? FocusPomodoroStore.StoreError == .duplicateSession) }
        let next = try await restored.apply(.start(id: second, plan: plan), at: wake)
        do {
            _ = try await restored.apply(.phase(id: first, step: 0, action: .cancel), at: wake)
            Issue.record("Old session action must not reach new session")
        } catch { #expect(error as? FocusPomodoroStore.StoreError == .staleSession) }
        #expect(try await restored.load() == next.session)
    }
}

@Test func focusPomodoroStorePreservesInvalidAndLinkedRecords() async throws {
    try await withPomodoroFile { file in
        let id = UUID(), plan = try FocusPomodoro.Plan()
        let store = FocusPomodoroStore(fileURL: file)
        let valid = try FocusPomodoro(id: id, plan: plan, now: epoch)
        var future = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(valid)) as? [String: Any])
        future["version"] = 2
        for bytes in [Data([0xff]), try JSONSerialization.data(withJSONObject: future),
                      Data(repeating: 0, count: FocusPomodoroStore.maximumRecordBytes + 1)] {
            try bytes.write(to: file, options: .atomic)
            do {
                _ = try await store.apply(.start(id: UUID(), plan: plan), at: epoch)
                Issue.record("Invalid record must not be replaced")
            } catch {
                if bytes.count > FocusPomodoroStore.maximumRecordBytes {
                    #expect(error as? FocusPomodoroStore.StoreError == .payloadTooLarge)
                }
            }
            #expect(try Data(contentsOf: file) == bytes)
        }
        try FileManager.default.removeItem(at: file)
        let target = file.deletingLastPathComponent().appendingPathComponent("other.json")
        let bytes = try JSONEncoder().encode(valid)
        try bytes.write(to: target)
        try FileManager.default.createSymbolicLink(at: file, withDestinationURL: target)
        do {
            _ = try await store.apply(.phase(id: id, step: 0, action: .cancel), at: epoch)
            Issue.record("Linked record must not be used")
        } catch { #expect(error as? FocusPomodoroStore.StoreError == .invalidBackingFile) }
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: file.path) == target.path)
        #expect(try Data(contentsOf: target) == bytes)
    }
}

import Foundation
import SchneeBarFocusCore
@testable import SchneeBarFocusPersistence
import Testing

private let origin = Date(timeIntervalSince1970: 1_700_000_000)

private func withCountdownFile(_ body: (URL) async throws -> Void) async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false,
        attributes: [.posixPermissions: 0o700])
    defer { try? FileManager.default.removeItem(at: directory) }
    try await body(directory.appendingPathComponent("countdown-v1.json"))
}

@Test func focusStoreRestoresDeadlineAndCommitsCompletionOnce() async throws {
    try await withCountdownFile { file in
        let first = FocusCountdownStore(fileURL: file)
        let id = UUID()
        #expect(try await first.load() == nil)
        let initial = try await first.apply(.start(id: id, duration: 60), at: origin)
        let bytes = try Data(contentsOf: file)
        let restored = FocusCountdownStore(fileURL: file)
        #expect(try await restored.load() == initial.countdown)
        let before = try await restored.apply(.reconcile(id: id), at: origin.addingTimeInterval(59))
        #expect(before.completion == nil && before.countdown == initial.countdown)
        #expect(try Data(contentsOf: file) == bytes)
        let wake = origin.addingTimeInterval(600)
        let complete = try await restored.apply(.reconcile(id: id), at: wake)
        #expect(complete.completion?.countdownID == id)
        #expect(complete.completion?.deadline == origin.addingTimeInterval(60))
        let restarted = FocusCountdownStore(fileURL: file)
        #expect(try await restarted.load() == complete.countdown)
        let replay = try await restarted.apply(.reconcile(id: id), at: wake)
        #expect(replay.completion == nil && replay.countdown == complete.countdown)
    }
}

@Test func focusStoreSerializesConcurrentCompletionAttempts() async throws {
    try await withCountdownFile { file in
        let store = FocusCountdownStore(fileURL: file)
        let id = UUID()
        _ = try await store.apply(.start(id: id, duration: 60), at: origin)
        let deadline = origin.addingTimeInterval(60)
        let completions = try await withThrowingTaskGroup(of: FocusCountdownStore.Result.self) { group in
            for _ in 0..<16 {
                group.addTask { try await store.apply(.reconcile(id: id), at: deadline) }
            }
            var count = 0
            for try await result in group {
                #expect(result.countdown.phase == .completed(deadline: deadline))
                if result.completion != nil { count += 1 }
            }
            return count
        }
        #expect(completions == 1)
        let saved = try await store.load()
        #expect(saved?.phase == .completed(deadline: deadline))
    }
}

@Test func focusStoreFailedCommitDoesNotExposeCompletionOrLoseRetry() async throws {
    enum Failure: Error { case write }
    try await withCountdownFile { file in
        let id = UUID()
        let good = FocusCountdownStore(fileURL: file)
        _ = try await good.apply(.start(id: id, duration: 60), at: origin)
        let previous = try Data(contentsOf: file)
        let failing = FocusCountdownStore(fileURL: file, read: { try Data(contentsOf: $0) },
            write: { _, _ in throw Failure.write })
        let deadline = origin.addingTimeInterval(60)
        do {
            _ = try await failing.apply(.reconcile(id: id), at: deadline)
            Issue.record("Failed commit must not yield a completion")
        } catch { #expect(error as? Failure == .write) }
        #expect(try Data(contentsOf: file) == previous)
        let retry = try await good.apply(.reconcile(id: id), at: deadline)
        #expect(retry.completion?.countdownID == id)
        let replay = try await good.apply(.reconcile(id: id), at: deadline)
        #expect(replay.completion == nil)
    }
}

@Test func focusStoreRejectsStaleAndDuplicateCommandsAndPreservesPausedState() async throws {
    try await withCountdownFile { file in
        let store = FocusCountdownStore(fileURL: file)
        let first = UUID(), next = UUID()
        _ = try await store.apply(.start(id: first, duration: 60), at: origin)
        let paused = try await store.apply(.pause(id: first), at: origin.addingTimeInterval(10))
        #expect(paused.countdown.phase == .paused(remaining: 50))
        let restored = FocusCountdownStore(fileURL: file)
        do {
            _ = try await restored.apply(.start(id: next, duration: 30), at: origin)
            Issue.record("Active countdown must not be replaced")
        } catch { #expect(error as? FocusCountdownStore.StoreError == .activeCountdown) }
        #expect(try await restored.load() == paused.countdown)
        let later = origin.addingTimeInterval(600)
        let resumed = try await restored.apply(.resume(id: first), at: later)
        #expect(resumed.countdown.phase == .running(deadline: later.addingTimeInterval(50)))
        _ = try await restored.apply(.cancel(id: first), at: later)
        do {
            _ = try await restored.apply(.start(id: first, duration: 30), at: later)
            Issue.record("Current record ID must not be reused")
        } catch { #expect(error as? FocusCountdownStore.StoreError == .duplicateCountdown) }
        let started = try await restored.apply(.start(id: next, duration: 30), at: later)
        do {
            _ = try await restored.apply(.cancel(id: first), at: later)
            Issue.record("Stale action must not affect replacement")
        } catch { #expect(error as? FocusCountdownStore.StoreError == .staleCountdown) }
        #expect(try await restored.load() == started.countdown)
    }
}

@Test func focusStorePreservesInvalidFutureOversizedAndLinkedRecords() async throws {
    try await withCountdownFile { file in
        let store = FocusCountdownStore(fileURL: file)
        let id = UUID()
        let valid = try FocusCountdown(id: id, duration: 60, now: origin)
        var future = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(valid)) as? [String: Any])
        future["version"] = 2
        let variants = [Data([0xff]), try JSONSerialization.data(withJSONObject: future),
            Data(repeating: 0, count: FocusCountdownStore.maximumRecordBytes + 1)]
        for bytes in variants {
            try bytes.write(to: file, options: .atomic)
            do {
                _ = try await store.apply(.start(id: UUID(), duration: 60), at: origin)
                Issue.record("Invalid backing record must not be replaced")
            } catch {
                if bytes.count > FocusCountdownStore.maximumRecordBytes {
                    #expect(error as? FocusCountdownStore.StoreError == .payloadTooLarge)
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
            _ = try await store.apply(.cancel(id: id), at: origin)
            Issue.record("Linked record must not be used")
        } catch { #expect(error as? FocusCountdownStore.StoreError == .invalidBackingFile) }
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: file.path) == target.path)
        #expect(try Data(contentsOf: target) == bytes)
    }
}

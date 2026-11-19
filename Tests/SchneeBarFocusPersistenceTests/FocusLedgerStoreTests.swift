import Foundation
import SchneeBarFocusCore
@testable import SchneeBarFocusPersistence
import Testing

private let ledgerOrigin = Date(timeIntervalSince1970: 1_700_000_000)

private func withLedger(_ body: (URL) async throws -> Void) async throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: false,
        attributes: [.posixPermissions: 0o700])
    defer { try? FileManager.default.removeItem(at: dir) }
    try await body(dir.appendingPathComponent("focus-ledger-v1.json"))
}

@Test func focusLedgerCommitsBothSlotsAndHistoryAcrossRestart() async throws {
    try await withLedger { file in
        let timer = UUID(), session = UUID()
        let plan = try FocusPomodoro.Plan(rounds: 2, focus: 10, shortBreak: 5)
        let store = FocusLedgerStore(fileURL: file)
        _ = try await store.apply(.countdown(.start(id: timer, duration: 8)), at: ledgerOrigin)
        _ = try await store.apply(.pomodoro(.start(id: session, plan: plan)), at: ledgerOrigin)
        let wake = ledgerOrigin.addingTimeInterval(60)
        let a = try await store.apply(.countdown(.reconcile(id: timer)), at: wake)
        #expect(a.completion != nil && a.snapshot.history.entries.count == 1)
        let b = try await store.apply(.pomodoro(.phase(id: session, step: 0, action: .reconcile)), at: wake)
        #expect(b.completion != nil && b.snapshot.history.entries.count == 2)
        let restored = FocusLedgerStore(fileURL: file)
        #expect(try await restored.load() == b.snapshot)
        let replay = try await restored.apply(.countdown(.reconcile(id: timer)), at: wake)
        #expect(replay.completion == nil && replay.snapshot == b.snapshot)
        let advanced = try await restored.apply(.pomodoro(.phase(id: session, step: 0, action: .advance)), at: wake)
        #expect(advanced.snapshot.history.entries == b.snapshot.history.entries)
        #expect(advanced.snapshot.pomodoro?.step == 1)
        _ = try await restored.apply(.countdown(.start(id: UUID(), duration: 10)), at: wake)
        #expect(try await restored.load().history.entries.count == 2)
        do {
            _ = try await restored.apply(.countdown(.start(id: timer, duration: 10)), at: wake)
            Issue.record("Retained identity must not be reused")
        } catch { #expect(error as? FocusLedgerStore.StoreError == .reusedIdentity) }
    }
}

@Test func focusLedgerFailedWriteLeavesStateAndHistoryUnchanged() async throws {
    enum Failure: Error { case write }
    try await withLedger { file in
        let id = UUID()
        let store = FocusLedgerStore(fileURL: file)
        let original = try await store.apply(.countdown(.start(id: id, duration: 10)), at: ledgerOrigin)
        let bytes = try Data(contentsOf: file)
        let failing = FocusLedgerStore(fileURL: file, read: { try Data(contentsOf: $0) },
            write: { _, _ in throw Failure.write })
        let end = ledgerOrigin.addingTimeInterval(10)
        do {
            _ = try await failing.apply(.countdown(.reconcile(id: id)), at: end)
            Issue.record("Failure must not publish completion")
        } catch { #expect(error as? Failure == .write) }
        #expect(try Data(contentsOf: file) == bytes)
        #expect(try await store.load() == original.snapshot)
        let retry = try await store.apply(.countdown(.reconcile(id: id)), at: end)
        #expect(retry.completion != nil && retry.snapshot.history.entries.count == 1)
        #expect(try await store.load() == retry.snapshot)
    }
}

@Test func focusLedgerConcurrentCompletionsNeverLoseEitherHistory() async throws {
    try await withLedger { file in
        let timer = UUID(), session = UUID()
        let plan = try FocusPomodoro.Plan(rounds: 1, focus: 10)
        let store = FocusLedgerStore(fileURL: file)
        _ = try await store.apply(.countdown(.start(id: timer, duration: 10)), at: ledgerOrigin)
        _ = try await store.apply(.pomodoro(.start(id: session, plan: plan)), at: ledgerOrigin)
        let end = ledgerOrigin.addingTimeInterval(10)
        let count = try await withThrowingTaskGroup(of: FocusLedgerStore.Result.self) { group in
            for index in 0..<16 {
                group.addTask {
                    let action: FocusLedgerStore.Command = index.isMultiple(of: 2)
                        ? .countdown(.reconcile(id: timer)) : .pomodoro(.phase(id: session, step: 0, action: .reconcile))
                    return try await store.apply(action, at: end)
                }
            }
            var events = 0
            for try await result in group { if result.completion != nil { events += 1 } }
            return events
        }
        #expect(count == 2)
        let saved = try await store.load()
        #expect(saved.history.entries.count == 2 && saved.pomodoro?.isFinished == true)
        #expect(saved.countdown?.phase == .completed(deadline: end))
    }
}

@Test func focusLedgerRejectsMissingHistoryAndPreservesCorruptBackingFile() async throws {
    try await withLedger { file in
        let id = UUID(), store = FocusLedgerStore(fileURL: file)
        _ = try await store.apply(.countdown(.start(id: id, duration: 10)), at: ledgerOrigin)
        _ = try await store.apply(.countdown(.reconcile(id: id)), at: ledgerOrigin.addingTimeInterval(10))
        let value = try Data(contentsOf: file)
        var json = try #require(JSONSerialization.jsonObject(with: value) as? [String: Any])
        json["history"] = ["version": 1, "entries": []] as [String: Any]
        let corrupt = try JSONSerialization.data(withJSONObject: json)
        try corrupt.write(to: file, options: .atomic)
        do {
            _ = try await store.apply(.countdown(.start(id: UUID(), duration: 10)), at: ledgerOrigin)
            Issue.record("Missing retained completion history must not be silently repaired")
        } catch { #expect(error as? FocusLedgerStore.StoreError == .inconsistentHistory) }
        #expect(try Data(contentsOf: file) == corrupt)
        try value.write(to: file, options: .atomic)
        #expect(try await store.load().history.entries.count == 1)
    }
}

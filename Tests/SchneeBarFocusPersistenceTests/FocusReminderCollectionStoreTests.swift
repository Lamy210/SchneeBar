import Foundation
import SchneeBarFocusCore
@testable import SchneeBarFocusPersistence
import Testing

private let origin = Date(timeIntervalSince1970: 1_700_000_000)
private let due = origin.addingTimeInterval(60)
private func withCollection(_ body: (URL) async throws -> Void) async throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: false,
        attributes: [.posixPermissions: 0o700])
    defer { try? FileManager.default.removeItem(at: dir) }
    try await body(dir.appendingPathComponent("reminders-v1.json"))
}

@Test func focusReminderCollectionRestoresIndependentClaimsAndRejectsRemovedIdentity() async throws {
    try await withCollection { file in
        let store = FocusReminderCollectionStore(fileURL: file)
        let a = try await store.add(title: "A", rule: .once(due))
        let b = try await store.add(title: "B", rule: .once(due))
        let calendar = Calendar(identifier: .gregorian)
        for entry in [a, b] {
            _ = try await store.apply(id: entry.id, command: .update(.setEnabled(true)), at: origin)
            _ = try await store.apply(id: entry.id, command: .update(.replan(calendar)), at: origin)
        }
        let restored = FocusReminderCollectionStore(fileURL: file)
        let before = try await restored.load()
        let aTicket = try #require(before.entries.first(where: { $0.id == a.id })?.state.pending)
        let bTicket = try #require(before.entries.first(where: { $0.id == b.id })?.state.pending)
        await #expect(throws: FocusReminderState.StateError.staleTicket) {
            try await restored.apply(id: b.id, command: .update(.claim(ticketID: aTicket.id, calendar: calendar)), at: due)
        }
        let claimed = try await restored.apply(id: a.id, command: .update(.claim(ticketID: aTicket.id, calendar: calendar)), at: due)
        #expect(claimed.claimed == aTicket.occurrence)
        #expect(claimed.snapshot.entries.first(where: { $0.id == b.id })?.state.pending == bTicket)
        _ = try await restored.apply(id: b.id, command: .remove, at: due)
        let replacement = try await restored.add(title: "B", rule: .once(due))
        #expect(replacement.id != b.id)
        await #expect(throws: FocusReminderCollectionStore.StoreError.staleReminder) {
            try await restored.apply(id: b.id, command: .update(.claim(ticketID: bTicket.id, calendar: calendar)), at: due)
        }
        let saved = try await restored.load()
        #expect(saved.entries.count == 2)
        #expect(saved.entries.first(where: { $0.id == a.id })?.state.lastObserved == aTicket.occurrence)
        #expect(saved.entries.first(where: { $0.id == replacement.id }) == replacement)
    }
}

@Test func focusReminderCollectionKeepsImportedInactiveAndRenamesWithoutChangingTicket() async throws {
    try await withCollection { file in
        let store = FocusReminderCollectionStore(fileURL: file)
        let imported = try await store.add(title: "Imported", rule: .once(due), origin: .imported)
        let native = try await store.add(title: "Native", rule: .once(due))
        let calendar = Calendar(identifier: .gregorian)
        await #expect(throws: FocusReminderState.StateError.importedInactive) {
            try await store.apply(id: imported.id, command: .update(.setEnabled(true)), at: origin)
        }
        _ = try await store.apply(id: native.id, command: .update(.setEnabled(true)), at: origin)
        let plan = try await store.apply(id: native.id, command: .update(.replan(calendar)), at: origin)
        let renamed = try await store.apply(id: native.id, command: .rename("新しい名前"), at: origin)
        #expect(renamed.snapshot.entries.first(where: { $0.id == native.id })?.title == "新しい名前")
        #expect(renamed.snapshot.entries.first(where: { $0.id == native.id })?.state == plan.snapshot.entries.first(where: { $0.id == native.id })?.state)
        #expect(renamed.snapshot.entries.first(where: { $0.id == imported.id }) == imported)
        for title in [" ", "bad\nname", String(repeating: "a", count: 129)] {
            await #expect(throws: FocusReminderCollectionStore.StoreError.invalidTitle) {
                try await store.apply(id: native.id, command: .rename(title), at: origin)
            }
        }
        #expect(try await store.load() == renamed.snapshot)
    }
}

@Test func focusReminderCollectionSerializesCapacityAndKeepsDeterministicOrder() async throws {
    try await withCollection { file in
        let store = FocusReminderCollectionStore(fileURL: file)
        let count = try await withThrowingTaskGroup(of: Bool.self) { group in
            for index in 0..<70 {
                group.addTask {
                    do { _ = try await store.add(title: "Reminder \(index)", rule: .once(due)); return true }
                    catch FocusReminderCollectionStore.StoreError.capacityExceeded { return false }
                }
            }
            var count = 0
            for try await added in group { if added { count += 1 } }
            return count
        }
        #expect(count == 64)
        let full = try await store.load()
        #expect(full.entries.count == 64)
        let ids = full.entries.map { $0.id.uuidString }
        #expect(ids == ids.sorted() && Set(ids).count == 64)
        let removed = try #require(full.entries.first)
        _ = try await store.apply(id: removed.id, command: .remove, at: origin)
        let added = try await store.add(title: "Replacement", rule: .once(due))
        #expect(added.id != removed.id)
        #expect(try await store.load().entries.count == 64)
    }
}

@Test func focusReminderCollectionFailedWriteDoesNotConsumeOrDeleteTicket() async throws {
    enum Failure: Error { case write }
    try await withCollection { file in
        let store = FocusReminderCollectionStore(fileURL: file)
        let a = try await store.add(title: "A", rule: .once(due))
        let calendar = Calendar(identifier: .gregorian)
        _ = try await store.apply(id: a.id, command: .update(.setEnabled(true)), at: origin)
        let plan = try await store.apply(id: a.id, command: .update(.replan(calendar)), at: origin)
        let ticket = try #require(plan.snapshot.entries.first?.state.pending)
        let bytes = try Data(contentsOf: file)
        let failing = FocusReminderCollectionStore(fileURL: file, read: { try Data(contentsOf: $0) },
            write: { _, _ in throw Failure.write })
        await #expect(throws: Failure.write) {
            try await failing.apply(id: a.id, command: .update(.claim(ticketID: ticket.id, calendar: calendar)), at: due)
        }
        await #expect(throws: Failure.write) {
            try await failing.apply(id: a.id, command: .remove, at: due)
        }
        #expect(try Data(contentsOf: file) == bytes)
        let retry = try await store.apply(id: a.id, command: .update(.claim(ticketID: ticket.id, calendar: calendar)), at: due)
        #expect(retry.claimed == ticket.occurrence)
        #expect(retry.snapshot.entries.first?.state.pending == nil)
    }
}

@Test func focusReminderCollectionRejectsDuplicateFutureAndOverCapacityRecords() async throws {
    try await withCollection { file in
        let store = FocusReminderCollectionStore(fileURL: file)
        _ = try await store.add(title: "A", rule: .once(due))
        let data = try Data(contentsOf: file)
        var json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let row = try #require((json["entries"] as? [[String: Any]])?.first)
        json["entries"] = [row, row]
        let duplicate = try JSONSerialization.data(withJSONObject: json)
        try duplicate.write(to: file, options: .atomic)
        await #expect(throws: FocusReminderCollectionStore.StoreError.duplicateIdentity) {
            try await store.add(title: "B", rule: .once(due))
        }
        #expect(try Data(contentsOf: file) == duplicate)
        json["entries"] = Array(repeating: row, count: 65)
        let large = try JSONSerialization.data(withJSONObject: json)
        try large.write(to: file, options: .atomic)
        await #expect(throws: FocusReminderCollectionStore.StoreError.capacityExceeded) { try await store.load() }
        #expect(try Data(contentsOf: file) == large)
        json["version"] = 2
        json["entries"] = [row]
        let future = try JSONSerialization.data(withJSONObject: json)
        try future.write(to: file, options: .atomic)
        await #expect(throws: FocusReminderCollectionStore.StoreError.unsupportedVersion) { try await store.load() }
        #expect(try Data(contentsOf: file) == future)
    }
}

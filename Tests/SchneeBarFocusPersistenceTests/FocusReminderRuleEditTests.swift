import Foundation
import SchneeBarFocusCore
@testable import SchneeBarFocusPersistence
import Testing

private let editOrigin = Date(timeIntervalSince1970: 1_700_000_000)
private let editCalendar = Calendar(identifier: .gregorian)

private func withEditFile(_ body: (URL) async throws -> Void) async throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: false,
        attributes: [.posixPermissions: 0o700])
    defer { try? FileManager.default.removeItem(at: dir) }
    try await body(dir.appendingPathComponent("reminders-v1.json"))
}

@Test func focusReminderRuleEditReplacesIdentityAndRevokesOldTicket() async throws {
    try await withEditFile { file in
        let store = FocusReminderCollectionStore(fileURL: file)
        let old = try await store.add(title: "Reminder", rule: .once(editOrigin.addingTimeInterval(60)))
        let other = try await store.add(title: "Other", rule: .daily(hour: 9, minute: 0))
        _ = try await store.apply(id: old.id, command: .update(.setEnabled(true)), at: editOrigin)
        let planned = try await store.apply(id: old.id, command: .update(.replan(editCalendar)), at: editOrigin)
        let oldTicket = try #require(planned.snapshot.entries.first(where: { $0.id == old.id })?.state.pending)
        let replacementDate = editOrigin.addingTimeInterval(120)
        let replacement = try await store.replaceRule(id: old.id, rule: .once(replacementDate),
                                                      at: editOrigin, calendar: editCalendar)
        #expect(replacement.id != old.id)
        #expect(replacement.title == old.title && replacement.state.enabled)
        #expect(replacement.state.pending?.occurrence.date == replacementDate)
        #expect(replacement.state.pending?.id != oldTicket.id && replacement.state.lastObserved == nil)
        let restored = FocusReminderCollectionStore(fileURL: file)
        let snapshot = try await restored.load()
        #expect(snapshot.entries.count == 2)
        #expect(snapshot.entries.contains(other) && snapshot.entries.contains(replacement))
        await #expect(throws: FocusReminderCollectionStore.StoreError.staleReminder) {
            try await restored.apply(id: old.id, command: .update(.claim(ticketID: oldTicket.id, calendar: editCalendar)), at: replacementDate)
        }
        await #expect(throws: FocusReminderState.StateError.staleTicket) {
            try await restored.apply(id: replacement.id, command: .update(.claim(ticketID: oldTicket.id, calendar: editCalendar)), at: replacementDate)
        }
        let ticket = try #require(replacement.state.pending)
        let claimed = try await restored.apply(id: replacement.id, command: .update(.claim(ticketID: ticket.id, calendar: editCalendar)), at: replacementDate)
        #expect(claimed.claimed == ticket.occurrence)
    }
}

@Test func focusReminderRuleEditCanonicalNoOpRetainsIdentityAndBytes() async throws {
    try await withEditFile { file in
        let store = FocusReminderCollectionStore(fileURL: file)
        let entry = try await store.add(title: "Weekdays", rule: .weekdays(hour: 9, minute: 0, days: [6, 2]))
        _ = try await store.apply(id: entry.id, command: .update(.setEnabled(true)), at: editOrigin)
        let plan = try await store.apply(id: entry.id, command: .update(.replan(editCalendar)), at: editOrigin)
        let expected = try #require(plan.snapshot.entries.first)
        let bytes = try Data(contentsOf: file)
        let unchanged = try await store.replaceRule(id: entry.id, rule: .weekdays(hour: 9, minute: 0, days: [2, 6]),
                                                    at: editOrigin, calendar: editCalendar)
        #expect(unchanged == expected)
        #expect(try Data(contentsOf: file) == bytes)
    }
}

@Test func focusReminderRuleEditPreservesDisabledIntentAndRejectsImportedAndInvalidRules() async throws {
    try await withEditFile { file in
        let store = FocusReminderCollectionStore(fileURL: file)
        let native = try await store.add(title: "Native", rule: .once(editOrigin.addingTimeInterval(60)))
        let imported = try await store.add(title: "Imported", rule: .daily(hour: 9, minute: 0), origin: .imported)
        let bytes = try Data(contentsOf: file)
        await #expect(throws: FocusReminderSchedule.ValidationError.invalidRule) {
            try await store.replaceRule(id: native.id, rule: .daily(hour: 24, minute: 0), at: editOrigin, calendar: editCalendar)
        }
        await #expect(throws: FocusReminderState.StateError.importedInactive) {
            try await store.replaceRule(id: imported.id, rule: .daily(hour: 10, minute: 0), at: editOrigin, calendar: editCalendar)
        }
        #expect(try Data(contentsOf: file) == bytes)
        let replacement = try await store.replaceRule(id: native.id, rule: .daily(hour: 10, minute: 0),
                                                      at: editOrigin, calendar: editCalendar)
        #expect(replacement.id != native.id && !replacement.state.enabled && replacement.state.pending == nil)
        #expect(try await store.load().entries.contains(imported))
    }
}

@Test func focusReminderRuleEditFailedWriteKeepsOldTicketClaimable() async throws {
    enum Failure: Error { case write }
    try await withEditFile { file in
        let store = FocusReminderCollectionStore(fileURL: file)
        let due = editOrigin.addingTimeInterval(60)
        let entry = try await store.add(title: "A", rule: .once(due))
        _ = try await store.apply(id: entry.id, command: .update(.setEnabled(true)), at: editOrigin)
        let planned = try await store.apply(id: entry.id, command: .update(.replan(editCalendar)), at: editOrigin)
        let ticket = try #require(planned.snapshot.entries.first?.state.pending)
        let bytes = try Data(contentsOf: file)
        let failing = FocusReminderCollectionStore(fileURL: file, read: { try Data(contentsOf: $0) },
            write: { _, _ in throw Failure.write })
        await #expect(throws: Failure.write) {
            try await failing.replaceRule(id: entry.id, rule: .daily(hour: 10, minute: 0), at: editOrigin, calendar: editCalendar)
        }
        #expect(try Data(contentsOf: file) == bytes)
        let claimed = try await store.apply(id: entry.id, command: .update(.claim(ticketID: ticket.id, calendar: editCalendar)), at: due)
        #expect(claimed.claimed == ticket.occurrence)
    }
}

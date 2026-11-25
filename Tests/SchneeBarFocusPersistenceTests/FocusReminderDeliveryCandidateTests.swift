import Foundation
import SchneeBarFocusCore
@testable import SchneeBarFocusPersistence
import Testing

@Test func focusDeliveryCandidatesOrderAndExactDeadline() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false,
                                           attributes: [.posixPermissions: 0o700])
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = FocusReminderCollectionStore(fileURL: directory.appendingPathComponent("reminders.json"))
    let now = Date(timeIntervalSince1970: 1_700_000_000)
    let due = now.addingTimeInterval(60)
    let calendar = Calendar(identifier: .gregorian)
    let a = try await store.add(title: "A", rule: .once(due))
    let b = try await store.add(title: "B", rule: .once(due))
    _ = try await store.add(title: "Disabled", rule: .once(due))
    _ = try await store.add(title: "Imported", rule: .once(due), origin: .imported)
    for id in [a.id, b.id] {
        _ = try await store.apply(id: id, command: .update(.setEnabled(true)), at: now)
        _ = try await store.apply(id: id, command: .update(.replan(calendar)), at: now)
    }
    let snapshot = try await store.load()
    let candidates = snapshot.deliveryCandidates
    #expect(candidates.count == 2)
    #expect(candidates.map(\.reminderID) == [a.id, b.id].sorted { $0.uuidString < $1.uuidString })
    #expect(candidates.allSatisfy { $0.kind == .regular && $0.deadline == due })
    #expect(snapshot.nextDeliveryDeadline == due)
    #expect(try snapshot.dueDeliveryCandidates(at: due.addingTimeInterval(-1)).isEmpty)
    #expect(try snapshot.dueDeliveryCandidates(at: due) == candidates)
    #expect(try snapshot.dueDeliveryCandidates(at: due.addingTimeInterval(1)) == candidates)
    #expect(throws: FocusReminderState.StateError.invalidClock) {
        try snapshot.dueDeliveryCandidates(at: Date(timeIntervalSince1970: .infinity))
    }
}

@Test func focusDeliveryCandidatesProjectSnoozeAndInvalidateOnDisable() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false,
                                           attributes: [.posixPermissions: 0o700])
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = FocusReminderCollectionStore(fileURL: directory.appendingPathComponent("reminders.json"))
    let now = Date(timeIntervalSince1970: 1_700_000_000)
    let due = now.addingTimeInterval(60)
    let snoozeDue = due.addingTimeInterval(60)
    let calendar = Calendar(identifier: .gregorian)
    let a = try await store.add(title: "A", rule: .once(due))
    let b = try await store.add(title: "B", rule: .once(snoozeDue))
    for id in [a.id, b.id] {
        _ = try await store.apply(id: id, command: .update(.setEnabled(true)), at: now)
        _ = try await store.apply(id: id, command: .update(.replan(calendar)), at: now)
    }
    let initial = try await store.load()
    let original = try #require(initial.deliveryCandidates.first)
    #expect(original.reminderID == a.id)
    _ = try await store.apply(id: a.id, command: .update(.claim(ticketID: original.ticketID, calendar: calendar)), at: due)
    _ = try await store.apply(id: a.id, command: .update(.snooze(sourceTicketID: original.ticketID, seconds: 60)), at: due)
    let current = try await store.load()
    let candidates = current.deliveryCandidates
    #expect(candidates.map(\.kind) == [.regular, .snooze])
    #expect(candidates.map(\.reminderID) == [b.id, a.id])
    #expect(candidates.allSatisfy { $0.deadline == snoozeDue })
    let delayed = try #require(candidates.last)
    #expect(delayed.ticketID != original.ticketID)
    #expect(try current.dueDeliveryCandidates(at: snoozeDue) == candidates)
    _ = try await store.apply(id: a.id, command: .update(.setEnabled(false)), at: due)
    let disabled = try await store.load()
    #expect(disabled.deliveryCandidates == Array(candidates.prefix(1)))
    await #expect(throws: FocusReminderState.StateError.staleTicket) {
        try await store.apply(id: a.id, command: .update(.claimSnooze(ticketID: delayed.ticketID)), at: snoozeDue)
    }
    _ = try await store.apply(id: b.id, command: .remove, at: due)
    let empty = try await store.load()
    #expect(empty.deliveryCandidates.isEmpty && empty.nextDeliveryDeadline == nil)
}

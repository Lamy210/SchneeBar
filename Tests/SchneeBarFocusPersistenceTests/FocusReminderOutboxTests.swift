import Foundation
import SchneeBarFocusCore
@testable import SchneeBarFocusPersistence
import Testing

private let outboxStart = Date(timeIntervalSince1970: 1_700_000_000)
private let outboxDue = outboxStart.addingTimeInterval(60)
private let outboxCalendar = Calendar(identifier: .gregorian)

private func withOutboxFile(_ body: (URL) async throws -> Void) async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false,
                                           attributes: [.posixPermissions: 0o700])
    defer { try? FileManager.default.removeItem(at: directory) }
    try await body(directory.appendingPathComponent("reminders.json"))
}

private func prepareOutboxReminder(_ store: FocusReminderCollectionStore, at due: Date = outboxDue) async throws
    -> (FocusReminderCollectionStore.Entry, FocusReminderState.Ticket) {
    let entry = try await store.add(title: "Reminder", rule: .once(due))
    _ = try await store.apply(id: entry.id, command: .update(.setEnabled(true)), at: outboxStart)
    let planned = try await store.apply(id: entry.id, command: .update(.replan(outboxCalendar)), at: outboxStart)
    let ticket = try #require(planned.snapshot.entries.first(where: { $0.id == entry.id })?.state.pending)
    return (entry, ticket)
}

@Test func reminderOutboxV1UpgradeAtomicClaimRestartAndAck() async throws {
    try await withOutboxFile { file in
        let store = FocusReminderCollectionStore(fileURL: file)
        let (entry, ticket) = try await prepareOutboxReminder(store)
        let old = try Data(contentsOf: file)
        let oldJSON = try #require(JSONSerialization.jsonObject(with: old) as? [String: Any])
        #expect(oldJSON["version"] as? Int == 2)
        // Simulate an existing v1 envelope (nested state version is independent).
        var legacy = oldJSON
        legacy["version"] = 1
        legacy.removeValue(forKey: "outbox")
        try JSONSerialization.data(withJSONObject: legacy).write(to: file, options: .atomic)
        #expect(try await store.load().outbox.isEmpty)
        let committed = try await store.apply(id: entry.id,
            command: .update(.claim(ticketID: ticket.id, calendar: outboxCalendar)), at: outboxDue)
        let event = try #require(committed.enqueued)
        #expect(committed.claimed == ticket.occurrence)
        #expect(event.reminderID == entry.id && event.ticketID == ticket.id)
        #expect(event.kind == .regular && event.deadline == outboxDue && event.claimedAt == outboxDue)
        #expect(committed.snapshot.outbox == [event])
        let rebooted = FocusReminderCollectionStore(fileURL: file)
        #expect(try await rebooted.load().outbox == [event])
        await #expect(throws: FocusReminderState.StateError.staleTicket) {
            try await rebooted.apply(id: entry.id,
                command: .update(.claim(ticketID: ticket.id, calendar: outboxCalendar)), at: outboxDue)
        }
        let acknowledged = try await rebooted.acknowledge(outboxID: event.id)
        #expect(acknowledged.outbox.isEmpty)
        await #expect(throws: FocusReminderCollectionStore.StoreError.staleOutbox) {
            try await rebooted.acknowledge(outboxID: event.id)
        }
        #expect(try await rebooted.load().entries.first?.state.lastObserved == ticket.occurrence)
    }
}

@Test func reminderOutboxSnoozeInvalidatesOriginalAndDisableRevokesQueued() async throws {
    try await withOutboxFile { file in
        let store = FocusReminderCollectionStore(fileURL: file)
        let (entry, ticket) = try await prepareOutboxReminder(store)
        let first = try await store.apply(id: entry.id,
            command: .update(.claim(ticketID: ticket.id, calendar: outboxCalendar)), at: outboxDue)
        #expect(first.snapshot.outbox.count == 1)
        let snoozed = try await store.apply(id: entry.id,
            command: .update(.snooze(sourceTicketID: ticket.id, seconds: 60)), at: outboxDue)
        #expect(snoozed.snapshot.outbox.isEmpty)
        let pending = try #require(snoozed.snapshot.entries.first?.state.pendingSnooze)
        let consumed = try await store.apply(id: entry.id,
            command: .update(.claimSnooze(ticketID: pending.id)), at: pending.deadline)
        let event = try #require(consumed.enqueued)
        #expect(consumed.claimedSnooze == pending && consumed.snapshot.outbox == [event])
        #expect(event.kind == .snooze && event.deadline == pending.deadline && event.ticketID == pending.id)
        _ = try await store.apply(id: entry.id, command: .update(.setEnabled(false)), at: pending.deadline)
        #expect(try await store.load().outbox.isEmpty)
        await #expect(throws: FocusReminderCollectionStore.StoreError.staleOutbox) {
            try await store.acknowledge(outboxID: event.id)
        }
    }
}

@Test func reminderOutboxWriteFailuresPreserveClaimAndAck() async throws {
    enum Failure: Error { case write }
    try await withOutboxFile { file in
        let store = FocusReminderCollectionStore(fileURL: file)
        let (entry, ticket) = try await prepareOutboxReminder(store)
        let original = try Data(contentsOf: file)
        let failing = FocusReminderCollectionStore(fileURL: file,
            read: { try Data(contentsOf: $0) }, write: { _, _ in throw Failure.write })
        await #expect(throws: Failure.write) {
            try await failing.apply(id: entry.id,
                command: .update(.claim(ticketID: ticket.id, calendar: outboxCalendar)), at: outboxDue)
        }
        #expect(try Data(contentsOf: file) == original)
        #expect(try await store.load().entries.first?.state.pending == ticket)
        let committed = try await store.apply(id: entry.id,
            command: .update(.claim(ticketID: ticket.id, calendar: outboxCalendar)), at: outboxDue)
        let event = try #require(committed.enqueued)
        let afterClaim = try Data(contentsOf: file)
        await #expect(throws: Failure.write) { try await failing.acknowledge(outboxID: event.id) }
        #expect(try Data(contentsOf: file) == afterClaim)
        #expect(try await store.load().outbox == [event])
        let replacement = try await store.replaceRule(id: entry.id,
            rule: .once(outboxDue.addingTimeInterval(120)), at: outboxDue, calendar: outboxCalendar)
        #expect(replacement.id != entry.id)
        #expect(try await store.load().outbox.isEmpty)
    }
}

@Test func reminderOutboxBackpressureNeverConsumesUnqueuedClaim() async throws {
    try await withOutboxFile { file in
        let store = FocusReminderCollectionStore(fileURL: file)
        let (a, ticketA) = try await prepareOutboxReminder(store)
        let (b, ticketB) = try await prepareOutboxReminder(store)
        let first = try await store.apply(id: a.id,
            command: .update(.claim(ticketID: ticketA.id, calendar: outboxCalendar)), at: outboxDue)
        let record = try #require(first.enqueued)
        var document = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
        let template = try #require((document["outbox"] as? [[String: Any]])?.first)
        document["outbox"] = (0..<FocusReminderCollectionStore.maximumOutboxEntries).map { _ -> [String: Any] in
            var row = template
            row["id"] = UUID().uuidString
            row["ticketID"] = UUID().uuidString
            return row
        }
        let full = try JSONSerialization.data(withJSONObject: document)
        try full.write(to: file, options: .atomic)
        #expect(try await store.load().outbox.count == FocusReminderCollectionStore.maximumOutboxEntries)
        await #expect(throws: FocusReminderCollectionStore.StoreError.outboxFull) {
            try await store.apply(id: b.id,
                command: .update(.claim(ticketID: ticketB.id, calendar: outboxCalendar)), at: outboxDue)
        }
        #expect(try Data(contentsOf: file) == full)
        #expect(try await store.load().entries.first(where: { $0.id == b.id })?.state.pending == ticketB)
        let toAck = try #require(try await store.load().outbox.first)
        _ = try await store.acknowledge(outboxID: toAck.id)
        let second = try await store.apply(id: b.id,
            command: .update(.claim(ticketID: ticketB.id, calendar: outboxCalendar)), at: outboxDue)
        #expect(second.enqueued?.ticketID == ticketB.id)
        #expect(second.snapshot.outbox.count == FocusReminderCollectionStore.maximumOutboxEntries)
        #expect(record.ticketID == ticketA.id)
    }
}

@Test func reminderOutboxRejectsDuplicateForeignAndMalformedPersistedRecords() async throws {
    try await withOutboxFile { file in
        let store = FocusReminderCollectionStore(fileURL: file)
        let (entry, ticket) = try await prepareOutboxReminder(store)
        _ = try await store.apply(id: entry.id,
            command: .update(.claim(ticketID: ticket.id, calendar: outboxCalendar)), at: outboxDue)
        let base = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
        let row = try #require((base["outbox"] as? [[String: Any]])?.first)
        var broken = base
        broken["outbox"] = [row, row]
        try JSONSerialization.data(withJSONObject: broken).write(to: file, options: .atomic)
        await #expect(throws: FocusReminderCollectionStore.StoreError.invalidOutbox) { try await store.load() }
        broken = base
        var foreign = row
        foreign["reminderID"] = UUID().uuidString
        broken["outbox"] = [foreign]
        try JSONSerialization.data(withJSONObject: broken).write(to: file, options: .atomic)
        await #expect(throws: FocusReminderCollectionStore.StoreError.invalidOutbox) { try await store.load() }
        broken = base
        broken["version"] = 1
        try JSONSerialization.data(withJSONObject: broken).write(to: file, options: .atomic)
        await #expect(throws: FocusReminderCollectionStore.StoreError.invalidOutbox) { try await store.load() }
        broken = base
        broken["version"] = 3
        try JSONSerialization.data(withJSONObject: broken).write(to: file, options: .atomic)
        await #expect(throws: FocusReminderCollectionStore.StoreError.unsupportedVersion) { try await store.load() }
    }
}


@Test func reminderObservedBatchAckIsAllOrNothingAndReplaySafe() async throws {
    try await withOutboxFile { file in
        let store = FocusReminderCollectionStore(fileURL: file)
        let (a, aTicket) = try await prepareOutboxReminder(store)
        let otherDue = outboxDue.addingTimeInterval(60)
        let (b, bTicket) = try await prepareOutboxReminder(store, at: otherDue)
        let aClaim = try await store.apply(id: a.id,
            command: .update(.claim(ticketID: aTicket.id, calendar: outboxCalendar)), at: outboxDue)
        let bClaim = try await store.apply(id: b.id,
            command: .update(.claim(ticketID: bTicket.id, calendar: outboxCalendar)), at: otherDue)
        let first = try #require(aClaim.enqueued)
        let second = try #require(bClaim.enqueued)
        let before = try Data(contentsOf: file)

        await #expect(throws: FocusReminderCollectionStore.StoreError.invalidOutbox) {
            try await store.acknowledgeObserved(records: [first, first])
        }
        let firstAfterDuplicate = try Data(contentsOf: file)
        #expect(firstAfterDuplicate == before)
        await #expect(throws: FocusReminderCollectionStore.StoreError.staleOutbox) {
            let source = try JSONEncoder().encode(first)
            var changed = try #require(JSONSerialization.jsonObject(with: source) as? [String: Any])
            changed["ticketID"] = UUID().uuidString
            let stale = try JSONDecoder().decode(FocusReminderOutboxRecord.self,
                from: JSONSerialization.data(withJSONObject: changed))
            try await store.acknowledgeObserved(records: [second, stale])
        }
        #expect(try Data(contentsOf: file) == before)
        #expect(try await store.acknowledgeObserved(records: []).outbox.count == 2)
        #expect(try Data(contentsOf: file) == before)

        let committed = try await store.acknowledgeObserved(records: [second, first])
        #expect(committed.outbox.isEmpty)
        #expect(try await store.load().outbox.isEmpty)
        await #expect(throws: FocusReminderCollectionStore.StoreError.staleOutbox) {
            try await store.acknowledgeObserved(records: [first])
        }
    }
}

@Test func reminderObservedBatchAckWriteFailureKeepsEntireQueue() async throws {
    enum Failure: Error { case write }
    try await withOutboxFile { file in
        let store = FocusReminderCollectionStore(fileURL: file)
        let (entry, ticket) = try await prepareOutboxReminder(store)
        let claimed = try await store.apply(id: entry.id,
            command: .update(.claim(ticketID: ticket.id, calendar: outboxCalendar)), at: outboxDue)
        let intent = try #require(claimed.enqueued)
        let before = try Data(contentsOf: file)
        let failed = FocusReminderCollectionStore(fileURL: file,
            read: { try Data(contentsOf: $0) }, write: { _, _ in throw Failure.write })
        await #expect(throws: Failure.write) {
            try await failed.acknowledgeObserved(records: [intent])
        }
        #expect(try Data(contentsOf: file) == before)
        #expect(try await store.load().outbox == [intent])
    }
}

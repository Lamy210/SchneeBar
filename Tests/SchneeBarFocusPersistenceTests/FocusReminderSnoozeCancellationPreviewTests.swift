import Foundation
import SchneeBarFocusCore
@testable import SchneeBarFocusPersistence
import Testing

private let candidateStart = Date(timeIntervalSince1970: 1_700_000_000)
private let candidateDue = candidateStart.addingTimeInterval(60)
private let candidateCalendar = Calendar(identifier: .gregorian)

private func withCandidateStore(_ body: (FocusReminderCollectionStore, URL) async throws -> Void) async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false,
                                           attributes: [.posixPermissions: 0o700])
    defer { try? FileManager.default.removeItem(at: directory) }
    let file = directory.appendingPathComponent("reminders.json")
    try await body(FocusReminderCollectionStore(fileURL: file), file)
}

private func prepareCandidate(_ store: FocusReminderCollectionStore, due: Date = candidateDue) async throws
    -> (UUID, FocusReminderState.SnoozeTicket) {
    let entry = try await store.add(title: "Local", rule: .once(due))
    _ = try await store.apply(id: entry.id, command: .update(.setEnabled(true)), at: candidateStart)
    let planned = try await store.apply(id: entry.id,
        command: .update(.replan(candidateCalendar)), at: candidateStart)
    let original = try #require(planned.snapshot.entries.first(where: { $0.id == entry.id })?.state.pending)
    _ = try await store.apply(id: entry.id,
        command: .update(.claim(ticketID: original.id, calendar: candidateCalendar)), at: due)
    let snoozed = try await store.apply(id: entry.id,
        command: .update(.snooze(sourceTicketID: original.id, seconds: 300)), at: due)
    let snooze = try #require(snoozed.snapshot.entries.first(where: { $0.id == entry.id })?.state.pendingSnooze)
    return (entry.id, snooze)
}

@Test func snoozeCancellationPreviewIsPurePendingAndScopedToReminder() async throws {
    try await withCandidateStore { store, file in
        let (id, snooze) = try await prepareCandidate(store)
        let bytes = try Data(contentsOf: file)
        let snapshot = try await store.load()
        let candidates = snapshot.snoozeCancellationCandidates()
        #expect(candidates.count == 1)
        let candidate = try #require(candidates.first)
        #expect(candidate.phase == .pending)
        #expect(candidate.reminderID == id)
        #expect(candidate.ticketID == snooze.id)
        #expect(candidate.deadline == snooze.deadline)
        #expect(snapshot.snoozeCancellationCandidates(for: id) == candidates)
        #expect(snapshot.snoozeCancellationCandidates(for: UUID()).isEmpty)
        #expect(try Data(contentsOf: file) == bytes)
    }
}

@Test func snoozeCancellationPreviewDistinguishesUnacknowledgedFromAccepted() async throws {
    try await withCandidateStore { store, file in
        let (id, snooze) = try await prepareCandidate(store)
        let claimed = try await store.apply(id: id,
            command: .update(.claimSnooze(ticketID: snooze.id)), at: snooze.deadline)
        let intent = try #require(claimed.enqueued)
        let restart = FocusReminderCollectionStore(fileURL: file)
        let snapshot = try await restart.load()
        let candidates = snapshot.snoozeCancellationCandidates()
        #expect(candidates.count == 1)
        let candidate = try #require(candidates.first)
        #expect(candidate.phase == .unacknowledgedOutbox)
        #expect(candidate.ticketID == snooze.id)
        #expect(candidate.reminderID == id)
        #expect(candidate.deadline == intent.deadline)
        _ = try await restart.acknowledge(outboxID: intent.id)
        #expect(try await restart.load().snoozeCancellationCandidates().isEmpty)
    }
}

@Test func snoozeCancellationPreviewUsesDeterministicDeadlineOrdering() async throws {
    try await withCandidateStore { store, file in
        let laterDue = candidateDue.addingTimeInterval(600)
        let (laterID, laterSnooze) = try await prepareCandidate(store, due: laterDue)
        let (earlierID, earlierSnooze) = try await prepareCandidate(store)
        let claimed = try await store.apply(id: laterID,
            command: .update(.claimSnooze(ticketID: laterSnooze.id)), at: laterSnooze.deadline)
        #expect(claimed.enqueued != nil)
        let snapshot = try await store.load()
        let candidates = snapshot.snoozeCancellationCandidates()
        #expect(candidates.count == 2)
        #expect(candidates.map(\.reminderID) == [earlierID, laterID])
        #expect(candidates.map(\.ticketID) == [earlierSnooze.id, laterSnooze.id])
        #expect(candidates.map(\.phase) == [.pending, .unacknowledgedOutbox])
        #expect(try await FocusReminderCollectionStore(fileURL: file).load()
            .snoozeCancellationCandidates() == candidates)
    }
}

@Test func snoozeCancellationPreviewExcludesRegularQueueAndDisabledReminders() async throws {
    try await withCandidateStore { store, _ in
        let entry = try await store.add(title: "No Snooze", rule: .once(candidateDue))
        _ = try await store.apply(id: entry.id,
            command: .update(.setEnabled(true)), at: candidateStart)
        let planned = try await store.apply(id: entry.id,
            command: .update(.replan(candidateCalendar)), at: candidateStart)
        let ticket = try #require(planned.snapshot.entries.first?.state.pending)
        let regular = try await store.apply(id: entry.id,
            command: .update(.claim(ticketID: ticket.id, calendar: candidateCalendar)), at: candidateDue)
        #expect(regular.enqueued?.kind == .regular)
        #expect(regular.snapshot.snoozeCancellationCandidates().isEmpty)
        _ = try await store.apply(id: entry.id,
            command: .update(.snooze(sourceTicketID: ticket.id, seconds: 300)), at: candidateDue)
        #expect(try await store.load().snoozeCancellationCandidates().count == 1)
        _ = try await store.apply(id: entry.id,
            command: .update(.setEnabled(false)), at: candidateDue)
        #expect(try await store.load().snoozeCancellationCandidates().isEmpty)
    }
}

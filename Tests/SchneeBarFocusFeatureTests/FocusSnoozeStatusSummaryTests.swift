import Foundation
import SchneeBarFocusCore
import SchneeBarFocusPersistence
@testable import SchneeBarFocusFeature
import Testing

private let summaryDeadline = Date(timeIntervalSince1970: 1_700_000_000)

private func summaryRow(
    _ phase: FocusReminderSnoozeCancellationCandidate.Phase,
    title: String = "Local reminder",
    reminderID: UUID = UUID(),
    ticketID: UUID = UUID()
) -> FocusSnoozeStatusRow {
    FocusSnoozeStatusRow(
        id: .init(reminderID: reminderID, ticketID: ticketID),
        title: title,
        deadline: summaryDeadline,
        phase: phase
    )
}

@Test func focusSnoozeSummaryEmptyStateIsZeroAndHasNoWarning() {
    let summary = FocusSnoozeStatusSummary(rows: [])
    #expect(summary.pendingCount == 0)
    #expect(summary.unconfirmedSubmissionCount == 0)
    #expect(summary.totalCount == 0)
    #expect(!summary.hasUnconfirmedSubmission)
}

@Test func focusSnoozeSummaryCountsPendingAndUnconfirmedSeparately() {
    let rows = [
        summaryRow(.pending),
        summaryRow(.unacknowledgedOutbox),
        summaryRow(.unacknowledgedOutbox),
        summaryRow(.pending),
    ]
    let summary = FocusSnoozeStatusSummary(rows: rows)
    #expect(summary.pendingCount == 2)
    #expect(summary.unconfirmedSubmissionCount == 2)
    #expect(summary.totalCount == rows.count)
    #expect(summary.hasUnconfirmedSubmission)
}

@Test func focusSnoozeSummaryDoesNotInferOSSubmissionFromOnlyPending() {
    let summary = FocusSnoozeStatusSummary(rows: [
        summaryRow(.pending), summaryRow(.pending)
    ])
    #expect(summary.pendingCount == 2)
    #expect(summary.unconfirmedSubmissionCount == 0)
    #expect(!summary.hasUnconfirmedSubmission)
}

@Test func focusSnoozeSummaryIsOrderAndIdentityIndependent() {
    let first = [
        summaryRow(.pending, title: "Private project"),
        summaryRow(.unacknowledgedOutbox, title: "Confidential context")
    ]
    let second = [
        summaryRow(.unacknowledgedOutbox, title: "Other title"),
        summaryRow(.pending, title: "Different title")
    ]
    #expect(FocusSnoozeStatusSummary(rows: first) == FocusSnoozeStatusSummary(rows: second))
}

@Test func focusSnoozeSummaryViewConstructionHasNoSideEffects() async {
    let summary = FocusSnoozeStatusSummary(rows: [
        summaryRow(.pending),
        summaryRow(.unacknowledgedOutbox)
    ])
    await MainActor.run {
        _ = FocusSnoozeStatusSummaryView(summary: summary)
    }
    #expect(summary.pendingCount == 1)
    #expect(summary.unconfirmedSubmissionCount == 1)
}

@Test func focusSnoozeSummaryReflectsPersistedPendingQueuedAndAcknowledgedStates() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(
        at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700]
    )
    defer { try? FileManager.default.removeItem(at: directory) }
    let path = directory.appendingPathComponent("reminders.json")
    let store = FocusReminderCollectionStore(fileURL: path)
    let start = Date(timeIntervalSince1970: 1_700_000_000)
    let due = start.addingTimeInterval(60)
    let calendar = Calendar(identifier: .gregorian)

    let reminder = try await store.add(title: "Read-only count", rule: .once(due))
    _ = try await store.apply(id: reminder.id, command: .update(.setEnabled(true)), at: start)
    let plan = try await store.apply(
        id: reminder.id, command: .update(.replan(calendar)), at: start
    )
    let regular = try #require(plan.snapshot.entries.first?.state.pending)
    _ = try await store.apply(
        id: reminder.id, command: .update(.claim(ticketID: regular.id, calendar: calendar)), at: due
    )
    let delayed = try await store.apply(
        id: reminder.id, command: .update(.snooze(sourceTicketID: regular.id, seconds: 300)), at: due
    )
    let ticket = try #require(delayed.snapshot.entries.first?.state.pendingSnooze)
    let coordinator = FocusSnoozeManagementCoordinator(store: store)
    let pending = try await coordinator.load()
    #expect(pending.summary.pendingCount == 1)
    #expect(pending.summary.unconfirmedSubmissionCount == 0)

    let claimed = try await store.apply(
        id: reminder.id, command: .update(.claimSnooze(ticketID: ticket.id)), at: ticket.deadline
    )
    let outbox = try #require(claimed.enqueued)
    let bytesBeforeRead = try Data(contentsOf: path)
    let queued = try await coordinator.load()
    #expect(queued.summary.pendingCount == 0)
    #expect(queued.summary.unconfirmedSubmissionCount == 1)
    #expect(queued.summary.hasUnconfirmedSubmission)
    #expect(try Data(contentsOf: path) == bytesBeforeRead)

    _ = try await store.acknowledge(outboxID: outbox.id)
    let acknowledged = try await coordinator.load()
    #expect(acknowledged.summary.totalCount == 0)
    #expect(!acknowledged.summary.hasUnconfirmedSubmission)
}

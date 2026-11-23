import Foundation
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

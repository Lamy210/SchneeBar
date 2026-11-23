import Foundation
import SchneeBarFocusPersistence
@testable import SchneeBarFocusFeature
import Testing

private let confirmationDeadline = Date(timeIntervalSince1970: 1_700_000_000)

private func makeConfirmationRow(
    phase: FocusReminderSnoozeCancellationCandidate.Phase,
    reminderID: UUID = UUID(),
    ticketID: UUID = UUID()
) -> FocusSnoozeStatusRow {
    FocusSnoozeStatusRow(
        id: .init(reminderID: reminderID, ticketID: ticketID),
        title: "Local pending reminder",
        deadline: confirmationDeadline,
        phase: phase
    )
}

@Test func focusSnoozeConfirmationOffersActionOnlyForPending() {
    let pending = makeConfirmationRow(phase: .pending)
    let queued = makeConfirmationRow(phase: .unacknowledgedOutbox)
    #expect(pending.offersPendingOnlyCancellation)
    #expect(!queued.offersPendingOnlyCancellation)
    #expect(queued.statusLabel.contains("may already be sent"))
}

@Test func focusSnoozeConfirmationRejectsQueuedPhaseWithSameIdentity() {
    let reminderID = UUID()
    let ticketID = UUID()
    let pending = makeConfirmationRow(
        phase: .pending, reminderID: reminderID, ticketID: ticketID
    )
    let queued = makeConfirmationRow(
        phase: .unacknowledgedOutbox, reminderID: reminderID, ticketID: ticketID
    )
    #expect(pending.id == queued.id)
    #expect(pending.offersPendingOnlyCancellation)
    #expect(!queued.offersPendingOnlyCancellation)
}

@Test func focusSnoozeConfirmationIsPureAndDoesNotMutateRow() {
    let row = makeConfirmationRow(phase: .pending)
    let before = row
    #expect(row.offersPendingOnlyCancellation)
    #expect(row == before)
    #expect(row.statusLabel == "Snooze scheduled")
}

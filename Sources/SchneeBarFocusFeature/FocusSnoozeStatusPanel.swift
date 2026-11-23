import Foundation
import SchneeBarFocusPersistence
import SwiftUI

/// UI-only representation of a single validated collection snapshot.
/// Rows are hints, not cancellation authorizations or OS delivery receipts.
public struct FocusSnoozeStatusRow: Equatable, Sendable, Identifiable {
    public struct ID: Hashable, Sendable {
        public let reminderID: UUID
        public let ticketID: UUID
    }

    public let id: ID
    public let title: String
    public let deadline: Date
    public let phase: FocusReminderSnoozeCancellationCandidate.Phase

    /// In particular, an unacknowledged Outbox item may already have been
    /// accepted by UserNotifications before the local ACK was persisted.
    public var statusLabel: String {
        switch phase {
        case .pending:
            return "Snooze scheduled"
        case .unacknowledgedOutbox:
            return "Notification submission unconfirmed; may already be sent"
        }
    }
}

/// Pure, bounded projection. The snapshot has already been decoded/validated
/// by its owner; no file, network, notification, or permission work occurs.
public struct FocusSnoozeStatusPresentation: Equatable, Sendable {
    public let rows: [FocusSnoozeStatusRow]

    public init(snapshot: FocusReminderCollectionStore.Snapshot) {
        let titles = Dictionary(uniqueKeysWithValues: snapshot.entries.map { ($0.id, $0.title) })
        rows = snapshot.snoozeCancellationCandidates().compactMap { candidate in
            guard let title = titles[candidate.reminderID] else { return nil }
            return FocusSnoozeStatusRow(
                id: .init(reminderID: candidate.reminderID, ticketID: candidate.ticketID),
                title: title,
                deadline: candidate.deadline,
                phase: candidate.phase
            )
        }
    }
}

/// A developer-only, read-only SwiftUI surface. No buttons or runtime wiring.
/// A future owner must reload the snapshot, verify the current ticket and
/// coordinate the OS boundary before offering an actual cancellation action.
@MainActor
public struct FocusSnoozeStatusPanel: View {
    private let presentation: FocusSnoozeStatusPresentation

    public init(snapshot: FocusReminderCollectionStore.Snapshot) {
        presentation = FocusSnoozeStatusPresentation(snapshot: snapshot)
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Snooze status")
                .font(.headline)
            Text("Read-only preview. This view does not cancel notifications.")
                .font(.caption)
                .foregroundStyle(.secondary)
            FocusSnoozeStatusSummaryView(summary: presentation.summary)

            if presentation.rows.isEmpty {
                Text("No active snoozes")
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("No active snoozes")
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 12) {
                        ForEach(presentation.rows) { row in
                            VStack(alignment: .leading, spacing: 4) {
                                Text(row.title)
                                    .font(.body)
                                Text(row.statusLabel)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                Text(row.deadline, format: .dateTime.year().month().day().hour().minute())
                                    .font(.caption)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.vertical, 4)
                            .accessibilityElement(children: .combine)
                            .accessibilityLabel(
                                "\(row.title), \(row.statusLabel), due \(row.deadline.formatted(date: .abbreviated, time: .shortened))"
                            )
                            .accessibilityHint("Read-only. Cancellation is not available in this view.")
                        }
                    }
                }
                .frame(maxHeight: 420)
            }
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

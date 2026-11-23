import Foundation
import SchneeBarFocusPersistence
import SwiftUI

/// Aggregated, read-only status. Deliberately contains no reminder titles,
/// ticket identifiers, or OS notification delivery assertions.
public struct FocusSnoozeStatusSummary: Equatable, Sendable {
    public let pendingCount: Int
    public let unconfirmedSubmissionCount: Int

    public var totalCount: Int { pendingCount + unconfirmedSubmissionCount }
    public var hasUnconfirmedSubmission: Bool { unconfirmedSubmissionCount > 0 }

    public init(rows: [FocusSnoozeStatusRow]) {
        var pending = 0
        var unconfirmed = 0
        for row in rows {
            switch row.phase {
            case .pending:
                pending += 1
            case .unacknowledgedOutbox:
                unconfirmed += 1
            }
        }
        pendingCount = pending
        unconfirmedSubmissionCount = unconfirmed
    }
}

extension FocusSnoozeStatusPresentation {
    /// The same already-loaded projection supplies both the rows and counts.
    /// This never reads a file or queries the OS.
    public var summary: FocusSnoozeStatusSummary {
        FocusSnoozeStatusSummary(rows: rows)
    }
}

/// An informational component only; it never offers an action or implies
/// that an unacknowledged notification is safe to retract.
@MainActor
public struct FocusSnoozeStatusSummaryView: View {
    private let summary: FocusSnoozeStatusSummary

    public init(summary: FocusSnoozeStatusSummary) {
        self.summary = summary
    }

    public var body: some View {
        if summary.totalCount > 0 {
            VStack(alignment: .leading, spacing: 4) {
                Text("Pending: \(summary.pendingCount) · Submission unconfirmed: \(summary.unconfirmedSubmissionCount)")
                    .font(.caption)
                    .accessibilityLabel(
                        "Pending Snoozes: \(summary.pendingCount). Notification submissions unconfirmed: \(summary.unconfirmedSubmissionCount)."
                    )
                if summary.hasUnconfirmedSubmission {
                    Text("Unconfirmed submissions may already have reached macOS. They cannot be cancelled here.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .accessibilityElement(children: .combine)
        }
    }
}

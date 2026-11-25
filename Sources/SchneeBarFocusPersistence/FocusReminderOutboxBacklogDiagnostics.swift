import Foundation

/// Privacy-preserving, read-only capacity/age diagnostics for the durable
/// Focus notification Outbox. These values do NOT prove OS delivery, authorize
/// resend, or establish a transport retry deadline.
public struct FocusReminderOutboxBacklogDiagnostics: Equatable, Sendable {
    public let queuedCount: Int
    public let remainingCapacity: Int
    public let agedCount: Int
    public let futureClaimCount: Int
    public let oldestClaimedAt: Date?

    public var isAtCapacity: Bool { remainingCapacity == 0 }
}

public enum FocusReminderOutboxDiagnosticsError: Error, Equatable, Sendable {
    case invalidObservationDate
    case invalidAgeThreshold
}

extension FocusReminderCollectionStore.Snapshot {
    /// Compute a point-in-time view without changing the Outbox or observing
    /// UserNotifications. Aged means claimedAt <= now - agedAfter; it does
    /// not mean the OS never accepted the notification.
    ///
    /// Invalid inputs fail closed instead of producing misleading counters.
    /// Future claimedAt values are surfaced separately for clock-regression
    /// investigation and are never classified as aged.
    public func outboxBacklogDiagnostics(
        at now: Date,
        agedAfter: TimeInterval
    ) throws -> FocusReminderOutboxBacklogDiagnostics {
        guard now.timeIntervalSinceReferenceDate.isFinite else {
            throw FocusReminderOutboxDiagnosticsError.invalidObservationDate
        }
        guard agedAfter.isFinite && agedAfter >= 0 else {
            throw FocusReminderOutboxDiagnosticsError.invalidAgeThreshold
        }

        var agedCount = 0
        var futureClaimCount = 0
        var oldestClaimedAt: Date?
        for record in outbox {
            let age = now.timeIntervalSince(record.claimedAt)
            if age < 0 {
                futureClaimCount += 1
            } else if age >= agedAfter {
                agedCount += 1
            }
            if let oldest = oldestClaimedAt {
                if record.claimedAt < oldest { oldestClaimedAt = record.claimedAt }
            } else {
                oldestClaimedAt = record.claimedAt
            }
        }

        return FocusReminderOutboxBacklogDiagnostics(
            queuedCount: outbox.count,
            remainingCapacity: max(0, FocusReminderCollectionStore.maximumOutboxEntries - outbox.count),
            agedCount: agedCount,
            futureClaimCount: futureClaimCount,
            oldestClaimedAt: oldestClaimedAt
        )
    }
}

import Foundation

/// Pure, read-only replay selection. A ready record is not a delivery receipt.
/// Stale records are retained for explicit recovery, never silently dropped.
public struct FocusReminderOutboxReplayPlan: Equatable, Sendable {
    public let ready: [FocusReminderOutboxRecord]
    public let heldForClock: [FocusReminderOutboxRecord]
    public let needsRecovery: [FocusReminderOutboxRecord]
    /// Eligible but omitted by the per-tick dispatch budget.
    public let deferredReadyCount: Int

    public var isEmpty: Bool {
        ready.isEmpty && heldForClock.isEmpty && needsRecovery.isEmpty && deferredReadyCount == 0
    }
}

extension FocusReminderCollectionStore.Snapshot {
    /// Return an idempotency-keyed replay batch without consuming or
    /// acknowledging anything. The owner must enforce single-writer dispatch
    /// and re-read this snapshot before each external side effect.
    ///
    /// - maxLateness: maximum elapsed seconds from the original deadline;
    ///   older records need an explicit policy decision, not auto-ack.
    /// - maxBatchSize: cap for one event-loop iteration to bound OS work.
    public func outboxReplayPlan(
        at now: Date, maxBatchSize: Int = 16, maxLateness: TimeInterval = 300
    ) throws -> FocusReminderOutboxReplayPlan {
        let nowSeconds = now.timeIntervalSince1970
        guard nowSeconds.isFinite,
              nowSeconds >= -62_135_596_800, nowSeconds < 253_402_300_800 else {
            throw FocusReminderOutboxReplayPolicyError.invalidClock
        }
        guard (1...FocusReminderCollectionStore.maximumOutboxEntries).contains(maxBatchSize) else {
            throw FocusReminderOutboxReplayPolicyError.invalidBatchSize
        }
        guard maxLateness.isFinite, (0...86_400).contains(maxLateness) else {
            throw FocusReminderOutboxReplayPolicyError.invalidLateness
        }

        // All records have already passed the file decoder's integrity checks.
        // Sort without depending on JSON insertion order or process hash seeds.
        let sorted = outbox.sorted { lhs, rhs in
            if lhs.deadline != rhs.deadline { return lhs.deadline < rhs.deadline }
            if lhs.kind != rhs.kind { return lhs.kind == .regular }
            if lhs.reminderID != rhs.reminderID {
                return lhs.reminderID.uuidString < rhs.reminderID.uuidString
            }
            return lhs.id.uuidString < rhs.id.uuidString
        }

        var eligible: [FocusReminderOutboxRecord] = []
        var clockHeld: [FocusReminderOutboxRecord] = []
        var recovery: [FocusReminderOutboxRecord] = []
        for intent in sorted {
            if intent.claimedAt > now {
                // A clock rollback cannot make an intent newly eligible.
                clockHeld.append(intent)
            } else if now.timeIntervalSince(intent.deadline) > maxLateness {
                // Never replay a missed reminder hours or days late by default.
                recovery.append(intent)
            } else {
                eligible.append(intent)
            }
        }

        return FocusReminderOutboxReplayPlan(
            ready: Array(eligible.prefix(maxBatchSize)),
            heldForClock: clockHeld,
            needsRecovery: recovery,
            deferredReadyCount: max(eligible.count - maxBatchSize, 0)
        )
    }
}

public enum FocusReminderOutboxReplayPolicyError: Error, Equatable, Sendable {
    case invalidClock, invalidBatchSize, invalidLateness
}

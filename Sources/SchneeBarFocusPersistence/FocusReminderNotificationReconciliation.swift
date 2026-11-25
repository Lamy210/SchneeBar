import Foundation

/// Stable request namespace owned by SchneeBar Focus only. Never use an
/// unvalidated external identifier for a remove/cancel operation.
public enum FocusReminderNotificationIdentity {
    public static let prefix = "dev.lamy.schneebar.focus."

    public static func identifier(for outboxID: UUID) -> String {
        prefix + outboxID.uuidString.lowercased()
    }

    /// Reject malformed or noncanonical identifiers, even when prefixed.
    public static func parseOwned(_ identifier: String) -> UUID? {
        guard identifier.hasPrefix(prefix) else { return nil }
        let suffix = String(identifier.dropFirst(prefix.count))
        guard let uuid = UUID(uuidString: suffix),
              identifier == Self.identifier(for: uuid) else { return nil }
        return uuid
    }
}

public enum FocusReminderNotificationReconciliationError: Error, Equatable, Sendable {
    case tooManySystemIdentifiers
}

/// Evidence-only view of the OS and our durable Outbox, not a mutation plan.
/// An absent OS request is ambiguous: it might have already been presented
/// and removed, so it must never cause automatic resubmission.
public struct FocusReminderNotificationReconciliationPlan: Equatable, Sendable {
    /// OS listed a request with the stable outbox UUID. The caller may
    /// revalidate the same authoritative intent before persisting an ACK.
    public let observedInSystem: [FocusReminderOutboxRecord]

    /// No active OS evidence. Must be reviewed before retry, never auto ACK.
    public let missingSystemEvidence: [FocusReminderOutboxRecord]

    /// OS requests under our namespace but not in the live Outbox.
    /// Might be previously acknowledged alerts, so do not auto-cancel.
    public let untrackedOwnedIdentifiers: [String]

    /// Unowned/noncanonical identifiers that must be left untouched.
    public let ignoredIdentifierCount: Int
}

extension FocusReminderCollectionStore.Snapshot {
    /// Pure reconciliation against a caller-provided OS pending/delivered
    /// snapshot. Both lists must be collected explicitly by the application
    /// owner; this does not query UserNotifications or alter durable state.
    public func reconcileNotificationIdentifiers(
        pending: [String],
        delivered: [String],
        maximumEvidenceCount: Int = 2_048
    ) throws -> FocusReminderNotificationReconciliationPlan {
        guard maximumEvidenceCount > 0, maximumEvidenceCount <= 65_536,
              pending.count <= maximumEvidenceCount,
              delivered.count <= maximumEvidenceCount - pending.count else {
            throw FocusReminderNotificationReconciliationError.tooManySystemIdentifiers
        }

        var owned = Set<String>()
        var ignored = 0
        for identifier in pending + delivered {
            if FocusReminderNotificationIdentity.parseOwned(identifier) != nil {
                owned.insert(identifier)
            } else {
                ignored += 1
            }
        }

        let intents = outbox.sorted { lhs, rhs in
            if lhs.deadline != rhs.deadline { return lhs.deadline < rhs.deadline }
            return lhs.id.uuidString < rhs.id.uuidString
        }
        var observed: [FocusReminderOutboxRecord] = []
        var missing: [FocusReminderOutboxRecord] = []
        for intent in intents {
            let identifier = FocusReminderNotificationIdentity.identifier(for: intent.id)
            if owned.remove(identifier) != nil {
                observed.append(intent)
            } else {
                missing.append(intent)
            }
        }

        return FocusReminderNotificationReconciliationPlan(
            observedInSystem: observed,
            missingSystemEvidence: missing,
            untrackedOwnedIdentifiers: owned.sorted(),
            ignoredIdentifierCount: ignored
        )
    }
}

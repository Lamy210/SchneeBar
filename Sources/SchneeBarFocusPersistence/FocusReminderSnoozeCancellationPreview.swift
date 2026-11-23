import Foundation
import SchneeBarFocusCore

/// Read-only UI hint, never an authorization or OS-cancellation receipt.
/// A queued intent may already have reached UserNotifications before ACK.
public struct FocusReminderSnoozeCancellationCandidate: Equatable, Sendable {
    public enum Phase: Equatable, Sendable {
        /// A Snooze has not yet been claimed into the delivery Outbox.
        case pending
        /// A Snooze was claimed, but durable OS acceptance was not ACKed.
        /// The OS may already have accepted the request.
        case unacknowledgedOutbox
    }

    public let reminderID: UUID
    public let ticketID: UUID
    public let deadline: Date
    public let phase: Phase
}

extension FocusReminderCollectionStore.Snapshot {
    /// Offer only exact ticket identities from one already-loaded snapshot.
    /// This function makes no file reads, clock assumptions, permission
    /// requests or OS notification calls. The owner must reload/revalidate
    /// on the actual cancellation command, not act on this staleable view.
    public func snoozeCancellationCandidates() -> [FocusReminderSnoozeCancellationCandidate] {
        let activeIDs = Set(entries.compactMap { entry in
            entry.state.enabled && entry.state.origin == .native ? entry.id : nil
        })

        let queued = outbox.filter { $0.kind == .snooze && activeIDs.contains($0.reminderID) }
        // If a corrupt or externally edited snapshot describes the same
        // ticket as pending and queued, show the more conservative phase.
        let queuedKeys = Set(queued.map { "\($0.reminderID.uuidString):\($0.ticketID.uuidString)" })
        var candidates: [FocusReminderSnoozeCancellationCandidate] = []
        for entry in entries where activeIDs.contains(entry.id) {
            guard let snooze = entry.state.pendingSnooze else { continue }
            let key = "\(entry.id.uuidString):\(snooze.id.uuidString)"
            guard !queuedKeys.contains(key) else { continue }
            candidates.append(.init(
                reminderID: entry.id,
                ticketID: snooze.id,
                deadline: snooze.deadline,
                phase: .pending
            ))
        }
        for intent in queued {
            candidates.append(.init(
                reminderID: intent.reminderID,
                ticketID: intent.ticketID,
                deadline: intent.deadline,
                phase: .unacknowledgedOutbox
            ))
        }

        return candidates.sorted { lhs, rhs in
            if lhs.deadline != rhs.deadline { return lhs.deadline < rhs.deadline }
            if lhs.reminderID != rhs.reminderID {
                return lhs.reminderID.uuidString < rhs.reminderID.uuidString
            }
            return lhs.ticketID.uuidString < rhs.ticketID.uuidString
        }
    }

    public func snoozeCancellationCandidates(for reminderID: UUID)
        -> [FocusReminderSnoozeCancellationCandidate] {
        snoozeCancellationCandidates().filter { $0.reminderID == reminderID }
    }
}

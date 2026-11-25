import Foundation
import SchneeBarFocusCore

/// Read-only scheduling projection. Candidates are not claims or delivery
/// receipts; the owner must revalidate their IDs in the store before effects.
public struct FocusReminderDeliveryCandidate: Equatable, Sendable {
    public enum Kind: Int, Equatable, Sendable {
        case regular = 0
        case snooze = 1
    }

    public let reminderID: UUID
    public let ticketID: UUID
    public let kind: Kind
    public let deadline: Date
}

extension FocusReminderCollectionStore.Snapshot {
    /// Absolute deadlines, with deterministic ties. No clock reads, title
    /// exposure, mutations, notification registration or missed-event policy.
    public var deliveryCandidates: [FocusReminderDeliveryCandidate] {
        var candidates: [FocusReminderDeliveryCandidate] = []
        for entry in entries where entry.state.enabled && entry.state.origin == .native {
            if let ticket = entry.state.pending {
                candidates.append(.init(reminderID: entry.id, ticketID: ticket.id,
                                        kind: .regular, deadline: ticket.occurrence.date))
            }
            if let ticket = entry.state.pendingSnooze {
                candidates.append(.init(reminderID: entry.id, ticketID: ticket.id,
                                        kind: .snooze, deadline: ticket.deadline))
            }
        }
        return candidates.sorted {
            if $0.deadline != $1.deadline { return $0.deadline < $1.deadline }
            if $0.kind != $1.kind { return $0.kind.rawValue < $1.kind.rawValue }
            if $0.reminderID != $1.reminderID { return $0.reminderID.uuidString < $1.reminderID.uuidString }
            return $0.ticketID.uuidString < $1.ticketID.uuidString
        }
    }

    public var nextDeliveryDeadline: Date? { deliveryCandidates.first?.deadline }

    /// Includes overdue candidates; eligibility is not a delivery decision.
    public func dueDeliveryCandidates(at now: Date) throws -> [FocusReminderDeliveryCandidate] {
        let seconds = now.timeIntervalSince1970
        guard seconds.isFinite && seconds >= -62_135_596_800 && seconds < 253_402_300_800 else {
            throw FocusReminderState.StateError.invalidClock
        }
        return Array(deliveryCandidates.prefix { $0.deadline <= now })
    }
}

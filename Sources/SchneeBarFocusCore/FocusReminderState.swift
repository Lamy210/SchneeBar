import Foundation

/// Durable scheduling intent, independent of OS notification permission.
/// A claim consumes an occurrence; it is not a delivery receipt.
public struct FocusReminderState: Equatable, Sendable, Codable {
    public enum Origin: String, Sendable, Codable { case native, imported }
    public enum StateError: Error, Equatable, Sendable {
        case importedInactive, staleTicket, notDue, invalidRecord, invalidClock, unsupportedVersion
        case invalidSnoozeDuration, snoozeWindowExpired
    }
    public struct Ticket: Equatable, Sendable, Codable {
        public let id: UUID
        public let occurrence: FocusReminderSchedule.Occurrence
    }

    public struct SnoozeOpportunity: Equatable, Sendable, Codable {
        public let ticketID: UUID
        public let claimedAt: Date
    }

    public struct SnoozeTicket: Equatable, Sendable, Codable {
        public let id: UUID
        public let occurrence: FocusReminderSchedule.Occurrence
        public let requestedAt: Date
        public let deadline: Date
    }

    public let schedule: FocusReminderSchedule
    public let origin: Origin
    public private(set) var enabled = false
    public private(set) var pending: Ticket?
    public private(set) var lastObserved: FocusReminderSchedule.Occurrence?
    public private(set) var snoozeOpportunity: SnoozeOpportunity?
    public private(set) var pendingSnooze: SnoozeTicket?

    public init(schedule: FocusReminderSchedule, origin: Origin = .native) {
        self.schedule = schedule
        self.origin = origin
    }

    public mutating func setEnabled(_ value: Bool) throws {
        guard !value || origin == .native else { throw StateError.importedInactive }
        enabled = value
        if !value {
            pending = nil
            snoozeOpportunity = nil
            pendingSnooze = nil
        }
    }

    /// Recalculate strictly future intent. A changed candidate invalidates
    /// the prior ticket. Replanning after a missed deadline skips it; use an
    /// explicit claim first if the owner intends to consume a due ticket.
    @discardableResult
    public mutating func replan(at now: Date, calendar: Calendar) throws -> Ticket? {
        guard enabled else { return nil }
        let occurrence = try schedule.next(after: now, calendar: calendar, lastObserved: lastObserved)
        if pending?.occurrence != occurrence {
            pending = occurrence.map { Ticket(id: UUID(), occurrence: $0) }
        }
        return pending
    }

    /// Reject stale/early claims, including a candidate invalidated by a
    /// time-zone change even if the caller has not replanned yet.
    public mutating func claim(ticketID: UUID, at now: Date, calendar: Calendar) throws -> FocusReminderSchedule.Occurrence {
        guard Self.validDate(now) else { throw StateError.invalidClock }
        guard enabled, let pending, pending.id == ticketID else { throw StateError.staleTicket }
        let occurrence = pending.occurrence
        guard now >= occurrence.date else { throw StateError.notDue }
        if occurrence.civilDay != nil {
            let current = try schedule.next(after: occurrence.date.addingTimeInterval(-1), calendar: calendar,
                                            lastObserved: lastObserved)
            guard current == occurrence else { throw StateError.staleTicket }
        }
        lastObserved = occurrence
        self.pending = nil
        pendingSnooze = nil
        snoozeOpportunity = SnoozeOpportunity(ticketID: ticketID, claimedAt: now)
        return occurrence
    }

    /// At most one snooze per consumed regular occurrence. The action must
    /// name its original ticket; a snooze never moves the recurrence cursor.
    public mutating func snooze(sourceTicketID: UUID, seconds: TimeInterval, at now: Date) throws {
        guard Self.validDate(now) else { throw StateError.invalidClock }
        guard enabled, let opportunity = snoozeOpportunity,
              opportunity.ticketID == sourceTicketID, let occurrence = lastObserved else {
            throw StateError.staleTicket
        }
        guard seconds.isFinite, (60...3600).contains(seconds) else { throw StateError.invalidSnoozeDuration }
        guard now >= opportunity.claimedAt, now.timeIntervalSince(opportunity.claimedAt) <= 3600 else {
            throw StateError.snoozeWindowExpired
        }
        let deadline = now.addingTimeInterval(seconds)
        guard Self.validDate(deadline), (60...3600).contains(deadline.timeIntervalSince(now)) else {
            throw StateError.invalidClock
        }
        pendingSnooze = SnoozeTicket(id: UUID(), occurrence: occurrence, requestedAt: now, deadline: deadline)
        snoozeOpportunity = nil
    }

    public mutating func claimSnooze(ticketID: UUID, at now: Date) throws -> SnoozeTicket {
        guard Self.validDate(now) else { throw StateError.invalidClock }
        guard enabled, let ticket = pendingSnooze, ticket.id == ticketID else { throw StateError.staleTicket }
        guard now >= ticket.deadline else { throw StateError.notDue }
        pendingSnooze = nil
        return ticket
    }

    private static func validDate(_ date: Date) -> Bool {
        let seconds = date.timeIntervalSince1970
        return seconds.isFinite && seconds >= -62_135_596_800 && seconds < 253_402_300_800
    }

    private enum CodingKeys: String, CodingKey { case version, schedule, origin, enabled, pending, lastObserved, snoozeOpportunity, pendingSnooze }

    public init(from decoder: Decoder) throws {
        let record = try decoder.container(keyedBy: CodingKeys.self)
        let version = try record.decode(Int.self, forKey: .version)
        guard version == 1 || version == 2 else { throw StateError.unsupportedVersion }
        schedule = try record.decode(FocusReminderSchedule.self, forKey: .schedule)
        origin = try record.decode(Origin.self, forKey: .origin)
        enabled = try record.decode(Bool.self, forKey: .enabled)
        pending = try record.decodeIfPresent(Ticket.self, forKey: .pending)
        lastObserved = try record.decodeIfPresent(FocusReminderSchedule.Occurrence.self, forKey: .lastObserved)
        guard (origin == .native || (!enabled && lastObserved == nil)), enabled || pending == nil else {
            throw StateError.invalidRecord
        }
        snoozeOpportunity = try record.decodeIfPresent(SnoozeOpportunity.self, forKey: .snoozeOpportunity)
        pendingSnooze = try record.decodeIfPresent(SnoozeTicket.self, forKey: .pendingSnooze)
        if version == 1, snoozeOpportunity != nil || pendingSnooze != nil { throw StateError.invalidRecord }
        if let lastObserved, !schedule.validCursor(lastObserved) { throw StateError.invalidRecord }
        if snoozeOpportunity != nil || pendingSnooze != nil {
            guard enabled, origin == .native, let lastObserved,
                  snoozeOpportunity == nil || pendingSnooze == nil else { throw StateError.invalidRecord }
            if let opportunity = snoozeOpportunity {
                guard Self.validDate(opportunity.claimedAt), opportunity.claimedAt >= lastObserved.date,
                      opportunity.ticketID != pending?.id else { throw StateError.invalidRecord }
            }
            if let ticket = pendingSnooze {
                let delay = ticket.deadline.timeIntervalSince(ticket.requestedAt)
                guard ticket.occurrence == lastObserved, Self.validDate(ticket.requestedAt),
                      Self.validDate(ticket.deadline), ticket.requestedAt >= lastObserved.date,
                      delay.isFinite, (60...3600).contains(delay), ticket.id != pending?.id else {
                    throw StateError.invalidRecord
                }
            }
        }
        if let pending {
            guard schedule.validCursor(pending.occurrence) else { throw StateError.invalidRecord }
            if let lastObserved {
                guard let observed = lastObserved.civilDay, let planned = pending.occurrence.civilDay,
                      planned > observed else { throw StateError.invalidRecord }
            }
        }
    }

    public func encode(to encoder: Encoder) throws {
        var record = encoder.container(keyedBy: CodingKeys.self)
        try record.encode(2, forKey: .version)
        try record.encode(schedule, forKey: .schedule)
        try record.encode(origin, forKey: .origin)
        try record.encode(enabled, forKey: .enabled)
        try record.encodeIfPresent(pending, forKey: .pending)
        try record.encodeIfPresent(lastObserved, forKey: .lastObserved)
        try record.encodeIfPresent(snoozeOpportunity, forKey: .snoozeOpportunity)
        try record.encodeIfPresent(pendingSnooze, forKey: .pendingSnooze)
    }
}

import Foundation

/// Durable intent to submit a claimed reminder to an eventual notification
/// adapter. Persisting an intent is NOT proof of OS acceptance or delivery.
/// The dispatcher should use 'id' as its stable idempotency key.
public struct FocusReminderOutboxRecord: Equatable, Sendable, Codable {
    public enum Kind: String, Equatable, Sendable, Codable {
        case regular, snooze
    }

    public let id: UUID
    public let reminderID: UUID
    public let ticketID: UUID
    public let kind: Kind
    public let deadline: Date
    public let claimedAt: Date

    init(reminderID: UUID, ticketID: UUID, kind: Kind, deadline: Date, claimedAt: Date) {
        id = UUID()
        self.reminderID = reminderID
        self.ticketID = ticketID
        self.kind = kind
        self.deadline = deadline
        self.claimedAt = claimedAt
    }

    private enum CodingKeys: String, CodingKey {
        case id, reminderID, ticketID, kind, deadline, claimedAt
    }

    public init(from decoder: Decoder) throws {
        let record = try decoder.container(keyedBy: CodingKeys.self)
        id = try record.decode(UUID.self, forKey: .id)
        reminderID = try record.decode(UUID.self, forKey: .reminderID)
        ticketID = try record.decode(UUID.self, forKey: .ticketID)
        kind = try record.decode(Kind.self, forKey: .kind)
        deadline = try record.decode(Date.self, forKey: .deadline)
        claimedAt = try record.decode(Date.self, forKey: .claimedAt)
        let lower = -62_135_596_800.0
        let upper = 253_402_300_800.0
        let at = claimedAt.timeIntervalSince1970
        let due = deadline.timeIntervalSince1970
        guard at.isFinite, due.isFinite, at >= lower, at < upper,
              due >= lower, due < upper, due <= at else {
            throw DecodingError.dataCorruptedError(
                forKey: .deadline, in: record, debugDescription: "Invalid outbox times"
            )
        }
    }
}

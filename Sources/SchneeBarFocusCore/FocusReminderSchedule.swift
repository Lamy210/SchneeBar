import Foundation

/// Pure recurrence calculation. Calendar and time zone are supplied by the
/// owner on each call; no persisted per-reminder time zone or OS effects.
public struct FocusReminderSchedule: Equatable, Sendable, Codable {
    public enum Rule: Equatable, Sendable, Codable {
        case once(Date)
        case daily(hour: Int, minute: Int)
        case weekdays(hour: Int, minute: Int, days: [Int])
    }

    public enum ValidationError: Error, Equatable, Sendable {
        case invalidRule, invalidClock, invalidCursor, unsupportedVersion, searchLimit
    }

    /// Gregorian civil date in the supplied time zone, independent of its
    /// identifier. The scheduling calendar itself need not be Gregorian.
    public struct CivilDay: Equatable, Comparable, Sendable {
        public let year: Int
        public let month: Int
        public let day: Int

        public static func < (lhs: Self, rhs: Self) -> Bool {
            (lhs.year, lhs.month, lhs.day) < (rhs.year, rhs.month, rhs.day)
        }
    }

    public struct Occurrence: Equatable, Sendable {
        public let reminderID: UUID
        public let date: Date
        public let civilDay: CivilDay?
    }

    public let id: UUID
    public let rule: Rule

    public init(id: UUID = UUID(), rule: Rule) throws {
        self.id = id
        switch rule {
        case .once(let date):
            guard Self.valid(date) else { throw ValidationError.invalidRule }
            self.rule = rule
        case .daily(let hour, let minute):
            guard Self.valid(hour: hour, minute: minute) else { throw ValidationError.invalidRule }
            self.rule = rule
        case .weekdays(let hour, let minute, let days):
            guard Self.valid(hour: hour, minute: minute), !days.isEmpty, days.count <= 7,
                  days.allSatisfy({ (1...7).contains($0) }), Set(days).count == days.count else {
                throw ValidationError.invalidRule
            }
            self.rule = .weekdays(hour: hour, minute: minute, days: days.sorted())
        }
    }

    /// Strictly future occurrence. For recurring items, lastObserved is a
    /// monotone civil-day high-water mark, not proof of system delivery.
    /// Never backfill earlier local days after clock rollback or travel.
    public func next(after now: Date, calendar: Calendar,
                     lastObserved: Occurrence? = nil) throws -> Occurrence? {
        guard Self.valid(now) else { throw ValidationError.invalidClock }
        if let lastObserved, lastObserved.reminderID != id { throw ValidationError.invalidCursor }
        let hour: Int, minute: Int, days: [Int]?
        switch rule {
        case .once(let date):
            if let lastObserved {
                guard lastObserved.civilDay == nil, lastObserved.date == date else { throw ValidationError.invalidCursor }
                return nil
            }
            return date > now ? .init(reminderID: id, date: date, civilDay: nil) : nil
        case .daily(let h, let m): (hour, minute, days) = (h, m, nil)
        case .weekdays(let h, let m, let d): (hour, minute, days) = (h, m, d)
        }
        if let lastObserved, lastObserved.civilDay == nil { throw ValidationError.invalidCursor }
        var civil = Calendar(identifier: .gregorian)
        civil.timeZone = calendar.timeZone
        var day = calendar.startOfDay(for: now)
        if let highWater = lastObserved?.civilDay, try Self.civilDay(for: day, in: civil) < highWater {
            // Jump close to the cursor even after a long rollback. Noon
            // avoids most midnight transitions; skipped dates normalize.
            guard let anchor = civil.date(from: DateComponents(year: highWater.year,
                month: highWater.month, day: highWater.day, hour: 12)), Self.valid(anchor) else {
                throw ValidationError.invalidCursor
            }
            day = calendar.startOfDay(for: anchor)
        }
        let matching = DateComponents(hour: hour, minute: minute, second: 0)
        // At most one candidate per civil day, with a bounded search.
        for _ in 0..<16 {
            guard Self.valid(day) else { throw ValidationError.searchLimit }
            let key = try Self.civilDay(for: day, in: civil)
            let unobserved = lastObserved?.civilDay.map { key > $0 } ?? true
            if unobserved, days?.contains(calendar.component(.weekday, from: day)) != false,
               let candidate = calendar.nextDate(after: day.addingTimeInterval(-1), matching: matching,
                   matchingPolicy: .nextTime, repeatedTimePolicy: .first, direction: .forward),
               calendar.isDate(candidate, inSameDayAs: day), candidate > now, Self.valid(candidate) {
                return .init(reminderID: id, date: candidate, civilDay: key)
            }
            guard let tomorrow = calendar.date(byAdding: .day, value: 1, to: day) else {
                throw ValidationError.searchLimit
            }
            let start = calendar.startOfDay(for: tomorrow)
            guard start > day else { throw ValidationError.searchLimit }
            day = start
        }
        throw ValidationError.searchLimit
    }

    private static func civilDay(for date: Date, in calendar: Calendar) throws -> CivilDay {
        let parts = calendar.dateComponents([.era, .year, .month, .day], from: date)
        guard parts.era == 1, let year = parts.year, let month = parts.month, let day = parts.day else {
            throw ValidationError.invalidClock
        }
        return .init(year: year, month: month, day: day)
    }

    private static func valid(hour: Int, minute: Int) -> Bool {
        (0...23).contains(hour) && (0...59).contains(minute)
    }

    private static func valid(_ date: Date) -> Bool {
        let seconds = date.timeIntervalSince1970
        return seconds.isFinite && seconds >= -62_135_596_800 && seconds < 253_402_300_800
    }

    private enum CodingKeys: String, CodingKey { case version, id, rule }

    public init(from decoder: Decoder) throws {
        let record = try decoder.container(keyedBy: CodingKeys.self)
        guard try record.decode(Int.self, forKey: .version) == 1 else { throw ValidationError.unsupportedVersion }
        try self.init(id: record.decode(UUID.self, forKey: .id), rule: record.decode(Rule.self, forKey: .rule))
    }

    public func encode(to encoder: Encoder) throws {
        var record = encoder.container(keyedBy: CodingKeys.self)
        try record.encode(1, forKey: .version)
        try record.encode(id, forKey: .id)
        try record.encode(rule, forKey: .rule)
    }
}

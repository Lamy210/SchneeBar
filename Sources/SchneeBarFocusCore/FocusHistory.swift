import Foundation

/// Bounded projection of completed native phases, not measured active time.
/// This value has no file, scheduling, migration or notification side effects.
public struct FocusHistory: Equatable, Sendable, Codable {
    public static let maximumEntries = 500

    public enum Kind: String, Equatable, Sendable, Codable {
        case countdown, focus, shortBreak, longBreak
    }

    public enum RecordResult: Equatable, Sendable {
        case retained, duplicate, outsideRetention, incomplete
    }

    public enum ValidationError: Error, Equatable, Sendable {
        case invalidEntry, duplicateIdentity, conflictingIdentity, tooManyEntries, unsupportedVersion
    }

    public struct Entry: Equatable, Sendable, Codable {
        public let sourceID: UUID
        public let step: Int?
        public let countdownID: UUID
        public let kind: Kind
        public let deadline: Date
        public let plannedDuration: TimeInterval

        fileprivate struct Identity: Hashable {
            let sourceID: UUID
            let step: Int?
        }

        fileprivate var identity: Identity { .init(sourceID: sourceID, step: step) }

        fileprivate init(sourceID: UUID, step: Int?, countdownID: UUID, kind: Kind,
                         deadline: Date, plannedDuration: TimeInterval) {
            self.sourceID = sourceID
            self.step = step
            self.countdownID = countdownID
            self.kind = kind
            self.deadline = deadline
            self.plannedDuration = plannedDuration
        }

        private enum CodingKeys: String, CodingKey {
            case sourceID, step, countdownID, kind, deadline, plannedDuration
        }

        public init(from decoder: Decoder) throws {
            let record = try decoder.container(keyedBy: CodingKeys.self)
            let sourceID = try record.decode(UUID.self, forKey: .sourceID)
            let step = try record.decodeIfPresent(Int.self, forKey: .step)
            let countdownID = try record.decode(UUID.self, forKey: .countdownID)
            let kind = try record.decode(Kind.self, forKey: .kind)
            let deadline = try record.decode(Date.self, forKey: .deadline)
            let duration = try record.decode(TimeInterval.self, forKey: .plannedDuration)
            let seconds = deadline.timeIntervalSince1970
            guard duration.isFinite, duration > 0, duration <= FocusCountdown.maximumDuration,
                  seconds.isFinite, seconds >= -62_135_596_800, seconds < 253_402_300_800 else {
                throw ValidationError.invalidEntry
            }
            if let step {
                guard (0...(2 * (FocusPomodoro.Plan.maximumRounds - 1))).contains(step),
                      duration >= 1,
                      step.isMultiple(of: 2) ? kind == .focus : (kind == .shortBreak || kind == .longBreak) else {
                    throw ValidationError.invalidEntry
                }
            } else {
                guard kind == .countdown, sourceID == countdownID else { throw ValidationError.invalidEntry }
            }
            self.init(sourceID: sourceID, step: step, countdownID: countdownID, kind: kind,
                      deadline: deadline, plannedDuration: duration)
        }
    }

    public private(set) var entries: [Entry] = []

    public init() {}

    @discardableResult
    public mutating func record(completed countdown: FocusCountdown) throws -> RecordResult {
        guard case .completed(let deadline) = countdown.phase else { return .incomplete }
        return try insert(.init(sourceID: countdown.id, step: nil, countdownID: countdown.id,
                                kind: .countdown, deadline: deadline, plannedDuration: countdown.duration))
    }

    @discardableResult
    public mutating func record(completed session: FocusPomodoro) throws -> RecordResult {
        guard case .completed(let deadline) = session.countdown.phase else { return .incomplete }
        let kind: Kind
        switch session.kind {
        case .focus: kind = .focus
        case .shortBreak: kind = .shortBreak
        case .longBreak: kind = .longBreak
        }
        return try insert(.init(sourceID: session.id, step: session.step, countdownID: session.countdown.id,
                                kind: kind, deadline: deadline, plannedDuration: session.countdown.duration))
    }

    private mutating func insert(_ entry: Entry) throws -> RecordResult {
        if let existing = entries.first(where: { $0.identity == entry.identity }) {
            guard existing == entry else { throw ValidationError.conflictingIdentity }
            return .duplicate
        }
        entries.append(entry)
        entries.sort(by: Self.precedes)
        if entries.count > Self.maximumEntries { entries.removeLast() }
        return entries.contains(entry) ? .retained : .outsideRetention
    }

    /// Newest deadline first, with deterministic tie breaks independent of insertion order.
    private static func precedes(_ lhs: Entry, _ rhs: Entry) -> Bool {
        if lhs.deadline != rhs.deadline { return lhs.deadline > rhs.deadline }
        if lhs.sourceID != rhs.sourceID { return lhs.sourceID.uuidString < rhs.sourceID.uuidString }
        return (lhs.step ?? -1) < (rhs.step ?? -1)
    }

    private enum CodingKeys: String, CodingKey { case version, entries }

    public init(from decoder: Decoder) throws {
        let record = try decoder.container(keyedBy: CodingKeys.self)
        guard try record.decode(Int.self, forKey: .version) == 1 else {
            throw ValidationError.unsupportedVersion
        }
        var list = try record.nestedUnkeyedContainer(forKey: .entries)
        if let count = list.count, count > Self.maximumEntries { throw ValidationError.tooManyEntries }
        var identities = Set<Entry.Identity>()
        var decoded: [Entry] = []
        while !list.isAtEnd {
            guard decoded.count < Self.maximumEntries else { throw ValidationError.tooManyEntries }
            let entry = try list.decode(Entry.self)
            guard identities.insert(entry.identity).inserted else { throw ValidationError.duplicateIdentity }
            decoded.append(entry)
        }
        entries = decoded.sorted(by: Self.precedes)
    }

    public func encode(to encoder: Encoder) throws {
        var record = encoder.container(keyedBy: CodingKeys.self)
        try record.encode(1, forKey: .version)
        try record.encode(entries, forKey: .entries)
    }
}

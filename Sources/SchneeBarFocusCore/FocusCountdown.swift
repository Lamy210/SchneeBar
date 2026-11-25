import Foundation

/// Native countdown domain. No scheduler, notification permission, legacy
/// storage, network, or UI dependency. The caller supplies the wall clock.
public struct FocusCountdown: Equatable, Sendable, Codable {
    public enum Phase: Equatable, Sendable, Codable {
        case running(deadline: Date)
        case paused(remaining: TimeInterval)
        case completed(deadline: Date)
        case cancelled
    }

    public struct Completion: Equatable, Sendable {
        public let countdownID: UUID
        public let deadline: Date
    }

    public enum ValidationError: Error, Equatable {
        case invalidDuration, invalidClock, invalidRecord, unsupportedVersion
    }

    // Proposed product bound; not a legacy-format compatibility claim.
    public static let maximumDuration: TimeInterval = 86_400
    public let id: UUID
    public let duration: TimeInterval
    public private(set) var phase: Phase

    public init(id: UUID = UUID(), duration: TimeInterval, now: Date) throws {
        guard Self.validDuration(duration) else { throw ValidationError.invalidDuration }
        let deadline = try Self.deadline(from: now, after: duration)
        self.id = id
        self.duration = duration
        self.phase = .running(deadline: deadline)
    }

    /// Display only: never change the authoritative deadline on a UI tick.
    public func remaining(at now: Date) throws -> TimeInterval {
        guard Self.validDate(now) else { throw ValidationError.invalidClock }
        switch phase {
        case .running(let deadline): return min(duration, max(0, deadline.timeIntervalSince(now)))
        case .paused(let remaining): return remaining
        case .completed, .cancelled: return 0
        }
    }

    /// Returns one completion per state transition. Persist the entire new
    /// record before dispatching external effects; this is not an exactly-once
    /// OS notification guarantee across a crash between commit and delivery.
    @discardableResult
    public mutating func reconcile(at now: Date) throws -> Completion? {
        guard Self.validDate(now) else { throw ValidationError.invalidClock }
        guard case .running(let deadline) = phase, now >= deadline else { return nil }
        phase = .completed(deadline: deadline)
        return Completion(countdownID: id, deadline: deadline)
    }

    /// Expiry wins over a late pause or cancel. A pause only captures the
    /// time remaining at the supplied clock, not at an earlier display tick.
    @discardableResult
    public mutating func pause(at now: Date) throws -> Completion? {
        if let completion = try reconcile(at: now) { return completion }
        guard case .running = phase else { return nil }
        phase = .paused(remaining: try remaining(at: now))
        return nil
    }

    public mutating func resume(at now: Date) throws {
        guard Self.validDate(now) else { throw ValidationError.invalidClock }
        guard case .paused(let remaining) = phase else { return }
        phase = .running(deadline: try Self.deadline(from: now, after: remaining))
    }

    @discardableResult
    public mutating func cancel(at now: Date) throws -> Completion? {
        if let completion = try reconcile(at: now) { return completion }
        switch phase {
        case .running, .paused: phase = .cancelled
        case .completed, .cancelled: break
        }
        return nil
    }

    private static func validDuration(_ value: TimeInterval) -> Bool {
        value.isFinite && value > 0 && value <= maximumDuration
    }

    private static func validDate(_ value: Date) -> Bool {
        // Gregorian years 0001 through 9999 in absolute UTC time.
        let seconds = value.timeIntervalSince1970
        return seconds.isFinite && seconds >= -62_135_596_800 && seconds < 253_402_300_800
    }

    private static func deadline(from now: Date, after remaining: TimeInterval) throws -> Date {
        guard validDate(now) else { throw ValidationError.invalidClock }
        let result = now.addingTimeInterval(remaining)
        guard validDate(result), result > now else { throw ValidationError.invalidClock }
        return result
    }

    private enum CodingKeys: String, CodingKey { case version, id, duration, phase }

    public init(from decoder: Decoder) throws {
        let record = try decoder.container(keyedBy: CodingKeys.self)
        guard try record.decode(Int.self, forKey: .version) == 1 else {
            throw ValidationError.unsupportedVersion
        }
        let id = try record.decode(UUID.self, forKey: .id)
        let duration = try record.decode(TimeInterval.self, forKey: .duration)
        let phase = try record.decode(Phase.self, forKey: .phase)
        guard Self.validDuration(duration) else { throw ValidationError.invalidRecord }
        switch phase {
        case .running(let deadline), .completed(let deadline):
            guard Self.validDate(deadline) else { throw ValidationError.invalidRecord }
        case .paused(let remaining):
            guard Self.validDuration(remaining), remaining <= duration else {
                throw ValidationError.invalidRecord
            }
        case .cancelled: break
        }
        self.id = id
        self.duration = duration
        self.phase = phase
    }

    public func encode(to encoder: Encoder) throws {
        var record = encoder.container(keyedBy: CodingKeys.self)
        try record.encode(1, forKey: .version)
        try record.encode(id, forKey: .id)
        try record.encode(duration, forKey: .duration)
        try record.encode(phase, forKey: .phase)
    }
}

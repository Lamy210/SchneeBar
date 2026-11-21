import Foundation

public enum CompanionPlaybackRate: Int, CaseIterable, Sendable {
    case half = 6, twoThirds = 8, normal = 12, oneAndHalf = 18, double = 24

    public var factor: Double { Double(rawValue) / 12 }
}

public enum CompanionClipError: Error, Equatable, Sendable {
    case invalidCount
    case invalidDuration
    case missingDefault
    case conflictingRevision
}

public struct CompanionClip: Equatable, Sendable {
    public let revision: UUID
    public let durations: [Double]

    public init(revision: UUID, durations: [Double]) throws {
        guard (1...120).contains(durations.count) else { throw CompanionClipError.invalidCount }
        guard durations.allSatisfy({ $0.isFinite && (0.02...10).contains($0) }) else {
            throw CompanionClipError.invalidDuration
        }
        self.revision = revision
        self.durations = durations
    }

    public func delay(at index: Int, rate: CompanionPlaybackRate) -> Double? {
        guard durations.indices.contains(index) else { return nil }
        return durations[index] / rate.factor
    }
}

public struct CompanionClipCatalog: Sendable {
    private let clips: [CompanionState: CompanionClip]
    private let fallback: CompanionClip

    public init(clips: [CompanionState: CompanionClip], defaultState: CompanionState) throws {
        guard let fallback = clips[defaultState] else { throw CompanionClipError.missingDefault }
        var revisions: [UUID: CompanionClip] = [:]
        for clip in clips.values {
            if let previous = revisions[clip.revision], previous != clip {
                throw CompanionClipError.conflictingRevision
            }
            revisions[clip.revision] = clip
        }
        self.clips = clips
        self.fallback = fallback
    }

    public func clip(for state: CompanionState) -> CompanionClip {
        clips[state] ?? fallback
    }
}

/// Pure frame scheduling decisions. Tokens are scoped to this cursor instance.
/// The renderer owns timer cancellation and must never route a callback to another cursor.
public struct CompanionPlaybackCursor: Sendable {
    public struct Tick: Equatable, Sendable {
        public let token: UInt64
        public let delay: Double
    }

    public private(set) var clip: CompanionClip?
    public private(set) var frameIndex = 0
    public private(set) var rate: CompanionPlaybackRate = .normal
    private var generation: UInt64 = 0

    public init() {}

    public var nextTick: Tick? {
        guard let clip, clip.durations.count > 1,
              let delay = clip.delay(at: frameIndex, rate: rate) else { return nil }
        return Tick(token: generation, delay: delay)
    }

    @discardableResult
    public mutating func select(_ next: CompanionClip?) -> Bool {
        guard clip != next else { return false }
        clip = next
        frameIndex = 0
        generation &+= 1
        return true
    }

    @discardableResult
    public mutating func setRate(_ next: CompanionPlaybackRate) -> Bool {
        guard rate != next else { return false }
        rate = next
        generation &+= 1
        return true
    }

    @discardableResult
    public mutating func tick(_ token: UInt64) -> Bool {
        guard let pending = nextTick, pending.token == token, let clip else { return false }
        frameIndex = (frameIndex + 1) % clip.durations.count
        generation &+= 1
        return true
    }
}

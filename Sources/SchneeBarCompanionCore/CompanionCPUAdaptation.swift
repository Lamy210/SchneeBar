/// Host utilization policy, independent of sampling, rendering and manual controls.
public struct CompanionCPUPace: Sendable {
    private static let states: [CompanionState] = [.idle, .walk, .run, .dash, .sprint]
    private static let rates: [CompanionPlaybackRate] = [.half, .twoThirds, .normal, .oneAndHalf, .double]
    private static let boundaries: [Double] = [0.15, 0.40, 0.70, 0.90]
    private var band = 0

    public init() {}

    public mutating func update(normalized: Double) -> CompanionCPUReaction? {
        guard normalized.isFinite, (0...1).contains(normalized) else {
            band = 0
            return nil
        }
        while band < Self.boundaries.count, normalized >= Self.boundaries[band] + 0.03 {
            band += 1
        }
        while band > 0, normalized < Self.boundaries[band - 1] - 0.03 {
            band -= 1
        }
        return CompanionCPUReaction(
            smoothedFraction: normalized, state: Self.states[band], rate: Self.rates[band]
        )
    }
}

public struct CompanionCPUReaction: Equatable, Sendable {
    /// Host usage normalized to the range 0...1.
    public let smoothedFraction: Double
    public let state: CompanionState
    public let rate: CompanionPlaybackRate
}

public struct CompanionCPUAdaptation: Sendable {
    private var pace = CompanionCPUPace()
    public private(set) var current: CompanionCPUReaction?

    public init() {}

    public mutating func accept(hostPercentage: Double?) -> CompanionCPUReaction? {
        guard let hostPercentage, hostPercentage.isFinite, (0...100).contains(hostPercentage) else {
            reset()
            return nil
        }
        let sample = hostPercentage / 100
        let ema = current.map { 0.25 * sample + 0.75 * $0.smoothedFraction } ?? sample
        current = pace.update(normalized: ema)
        return current
    }

    public mutating func reset() {
        current = nil
        pace = CompanionCPUPace()
    }
}

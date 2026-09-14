public struct WidgetRuntimeLifecycle: Sendable {
    public struct Generation: Equatable, Sendable {
        fileprivate let value: UInt64
    }

    public private(set) var isSleeping = false
    private var sequence: UInt64 = 0

    public init() {}

    /// Starts a new awake runtime generation.
    ///
    /// Returns `nil` while the system is sleeping so callers cannot accidentally
    /// schedule provider work before a wake transition creates a fresh generation.
    public mutating func beginRuntime() -> Generation? {
        guard !isSleeping else { return nil }

        sequence &+= 1
        return Generation(value: sequence)
    }

    /// Suspends the runtime and invalidates all generations created before sleep.
    public mutating func willSleep() {
        guard !isSleeping else { return }

        isSleeping = true
        sequence &+= 1
    }

    /// Resumes from sleep with a fresh generation.
    ///
    /// Duplicate wake notifications are ignored rather than rotating the current
    /// generation out from under already-running post-wake work.
    public mutating func didWake() -> Generation? {
        guard isSleeping else { return nil }

        isSleeping = false
        sequence &+= 1
        return Generation(value: sequence)
    }

    public func isCurrent(_ generation: Generation) -> Bool {
        !isSleeping && generation.value == sequence
    }
}

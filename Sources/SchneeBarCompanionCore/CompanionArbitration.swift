import Foundation

public enum CompanionState: Hashable, Sendable {
    case idle, walk, run, dash, sprint
}

/// Normalized internal identities. Adapters, not external payloads, choose provenance.
public enum CompanionSource: Hashable, Sendable {
    case manual, cpu, localBuild, productivity
    case systemAdvisory(UUID), systemEvent(UUID), localState(UUID), developer(UUID)

    public var priority: Int {
        switch self {
        case .manual: 1000
        case .localBuild, .localState, .productivity, .developer: 500
        case .systemEvent: 400
        case .systemAdvisory: 300
        case .cpu: 100
        }
    }

    fileprivate var isReserved: Bool {
        self == .manual || self == .cpu
    }

    fileprivate var isLocal: Bool {
        switch self {
        case .localBuild, .localState: true
        default: false
        }
    }
}

/// A single-owner value policy; the caller supplies elapsed monotonic time.
/// No timers, external input, or runtime side effects are owned here.
public struct CompanionArbitration: Sendable {
    private struct Entry: Sendable {
        let source: CompanionSource
        let state: CompanionState
        let deadline: Duration?
    }

    private var entries: [Entry] = []
    private var time: Duration = .zero

    public init() {}

    public var state: CompanionState { winner?.state ?? .run }
    public var winningSource: CompanionSource? { winner?.source }
    public var nextDeadline: Duration? { entries.compactMap(\.deadline).min() }

    private var winner: Entry? {
        var result: Entry?
        for entry in entries {
            if let current = result, current.source.priority > entry.source.priority {
                continue
            }
            result = entry
        }
        return result
    }

    /// Returns false on clock regression, without changing stored state.
    @discardableResult
    public mutating func advance(to now: Duration) -> Bool {
        guard now >= time else { return false }
        time = now
        entries.removeAll { entry in
            entry.deadline.map { $0 <= now } ?? false
        }
        return true
    }

    /// Reconcile expiry first, then accept a valid replacement or insert.
    /// A rejected insert cannot evict another live trigger.
    @discardableResult
    public mutating func submit(
        _ state: CompanionState,
        from source: CompanionSource,
        at now: Duration,
        until deadline: Duration? = nil
    ) -> Bool {
        guard advance(to: now) else { return false }
        if let deadline, deadline <= now { return false }
        if source == .manual, deadline != nil { return false }
        if source.isLocal {
            guard let deadline, deadline - now <= .seconds(3600) else { return false }
        }

        if let index = entries.firstIndex(where: { $0.source == source }) {
            entries.remove(at: index)
        } else {
            if !source.isReserved,
               entries.filter({ !$0.source.isReserved }).count >= 126 { return false }
            if source.isLocal,
               entries.filter({ $0.source.isLocal }).count >= 64 { return false }
        }
        entries.append(Entry(source: source, state: state, deadline: deadline))
        return true
    }

    /// Explicit removal reconciles expiry at the same monotonic observation.
    @discardableResult
    public mutating func clear(_ source: CompanionSource, at now: Duration) -> Bool {
        guard advance(to: now) else { return false }
        entries.removeAll { $0.source == source }
        return true
    }

    /// Local ingress quarantine must not cancel trusted or user-owned state.
    @discardableResult
    public mutating func clearLocal(at now: Duration) -> Bool {
        guard advance(to: now) else { return false }
        entries.removeAll { $0.source.isLocal }
        return true
    }
}

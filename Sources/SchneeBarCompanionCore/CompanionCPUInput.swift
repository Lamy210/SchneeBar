import Foundation

/// No platform sampler or scheduler dependency. The runtime issues request
/// tokens before fetching; only the newest request in the active session may
/// mutate this value. Manual speed disables automatic CPU contribution.
public struct CompanionCPUInput: Sendable {
    public struct Request: Equatable, Sendable {
        fileprivate let session: UUID
        fileprivate let order: UInt64
    }

    public enum Mode: Equatable, Sendable {
        case disabled
        case automatic
        case manual(CompanionPlaybackRate)
    }

    public private(set) var mode: Mode = .disabled
    public private(set) var reaction: CompanionCPUReaction?
    private var adaptation = CompanionCPUAdaptation()
    private var session = UUID()
    private var order: UInt64 = 0
    private var pending: Request?
    private var lastID: UUID?
    private var lastEpoch: UUID?
    private var lastInstant: ContinuousClock.Instant?

    public init() {}

    public var rate: CompanionPlaybackRate {
        switch mode {
        case .disabled: .normal
        case .manual(let rate): rate
        case .automatic: reaction?.rate ?? .normal
        }
    }

    public mutating func setMode(_ newMode: Mode) {
        guard mode != newMode else { return }
        mode = newMode
        invalidateSession()
    }

    /// Called for sleep, disable, or replacement of the upstream lease.
    public mutating func invalidateSession() {
        session = UUID()
        order = 0
        pending = nil
        lastID = nil
        lastEpoch = nil
        lastInstant = nil
        adaptation.reset()
        reaction = nil
    }

    public mutating func beginRequest() -> Request? {
        guard mode == .automatic else { return nil }
        order &+= 1
        let request = Request(session: session, order: order)
        pending = request
        return request
    }

    @discardableResult
    public mutating func accept(
        _ request: Request, id: UUID, epoch: UUID,
        capturedAt: ContinuousClock.Instant, hostPercentage: Double
    ) -> Bool {
        guard mode == .automatic, pending == request else { return false }
        pending = nil
        if lastID == id { return false }
        if let lastInstant, capturedAt <= lastInstant { return false }
        if let lastEpoch, lastEpoch != epoch { adaptation.reset() }
        lastID = id
        lastEpoch = epoch
        lastInstant = capturedAt
        reaction = adaptation.accept(hostPercentage: hostPercentage)
        return true
    }

    @discardableResult
    public mutating func unavailable(_ request: Request) -> Bool {
        guard mode == .automatic, pending == request else { return false }
        pending = nil
        adaptation.reset()
        reaction = nil
        // Retain last-seen sample identity/time so a cached success cannot
        // resurrect expired data after an error in the same session.
        return true
    }
}

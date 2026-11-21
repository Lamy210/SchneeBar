import Foundation

/// One composition owner serializes all lease transitions with its existing
/// short configuration operations. Never enqueue a counter read or refresh
/// loop here. The caller fences presentation with its own generation.
@MainActor
public final class HostCPUDemandTransitions {
    private let sampler: HostCPUSampler
    public private(set) var latest: Task<Void, Never>?
    public private(set) var isFinished = false

    public init(sampler: HostCPUSampler) {
        self.sampler = sampler
    }

    /// Preserve every transition, including temporary sleep/disable. Do not
    /// cancel a transition to coalesce it: that would skip lease revocation.
    /// The returned handle is for awaiting, not cancellation. After finish,
    /// all submissions return the terminal handle and ignore subsequent work.
    @discardableResult
    public func enqueue(widget: Bool, companion: Bool, sleeping: Bool,
                        after: @escaping @MainActor () async -> Void = {}) -> Task<Void, Never> {
        if isFinished, let latest { return latest }
        return schedule(widget: widget, companion: companion, sleeping: sleeping, after: after)
    }

    /// Terminal suspension follows all prior operations. No new transition
    /// can resume this sampler through this owner after this call.
    @discardableResult
    public func finish() -> Task<Void, Never> {
        if isFinished, let latest { return latest }
        isFinished = true
        return schedule(widget: false, companion: false, sleeping: true, after: {})
    }

    private func schedule(widget: Bool, companion: Bool, sleeping: Bool,
                          after: @escaping @MainActor () async -> Void) -> Task<Void, Never> {
        let previous = latest
        let sampler = sampler
        let task = Task { @MainActor in
            await previous?.value
            // A cancelled await handle does not cancel the required lease
            // transition. Callbacks should be short configuration operations.
            await sampler.reconcileDemand(widget: widget, companion: companion, sleeping: sleeping)
            await after()
        }
        latest = task
        return task
    }
}

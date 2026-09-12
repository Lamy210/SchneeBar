import Foundation

public actor WidgetEngine {
    private var providers: [WidgetID: any WidgetProvider]
    private var snapshots: [WidgetID: WidgetSnapshot] = [:]
    private var lastAttemptedAt: [WidgetID: Date] = [:]

    public init(providers: [any WidgetProvider] = []) {
        self.providers = Dictionary(
            uniqueKeysWithValues: providers.map { ($0.descriptor.id, $0) }
        )
    }

    public func register(_ provider: any WidgetProvider) {
        providers[provider.descriptor.id] = provider
    }

    public func unregister(id: WidgetID) {
        providers.removeValue(forKey: id)
        snapshots.removeValue(forKey: id)
        lastAttemptedAt.removeValue(forKey: id)
    }

    @discardableResult
    public func refresh(id: WidgetID, at attemptedAt: Date = .now) async -> WidgetSnapshot? {
        guard let provider = providers[id] else { return nil }
        lastAttemptedAt[id] = attemptedAt

        do {
            let snapshot = try await provider.snapshot()
            snapshots[id] = snapshot
            return snapshot
        } catch {
            // Preserve the last known-good value. A later phase will expose
            // provider diagnostics without leaking provider-specific errors
            // into presentation code.
            return snapshots[id]
        }
    }

    @discardableResult
    public func refreshAll(at attemptedAt: Date = .now) async -> [WidgetSnapshot] {
        for id in orderedProviderIDs() {
            _ = await refresh(id: id, at: attemptedAt)
        }
        return orderedVisibleSnapshots()
    }

    @discardableResult
    public func refreshDue(at now: Date = .now) async -> [WidgetSnapshot] {
        for id in orderedProviderIDs() where isRefreshDue(id: id, at: now) {
            _ = await refresh(id: id, at: now)
        }
        return orderedVisibleSnapshots()
    }

    public func secondsUntilNextRefresh(
        at now: Date = .now,
        maximum: TimeInterval = 60
    ) -> TimeInterval {
        let intervals = providers.compactMap { id, provider -> TimeInterval? in
            guard let snapshot = snapshots[id] else { return 0 }
            guard let interval = provider.descriptor.refreshPolicy.interval(for: snapshot.severity) else {
                return nil
            }
            guard let lastAttempted = lastAttemptedAt[id] else { return 0 }

            let next = lastAttempted.addingTimeInterval(interval)
            return max(0, next.timeIntervalSince(now))
        }

        return min(intervals.min() ?? maximum, maximum)
    }

    public func snapshot(id: WidgetID) -> WidgetSnapshot? {
        snapshots[id]
    }

    public func orderedVisibleSnapshots() -> [WidgetSnapshot] {
        snapshots.values
            .filter(\.isVisible)
            .sorted { lhs, rhs in
                if lhs.priority != rhs.priority {
                    return lhs.priority > rhs.priority
                }
                return lhs.descriptor.id.rawValue < rhs.descriptor.id.rawValue
            }
    }

    private func orderedProviderIDs() -> [WidgetID] {
        providers.keys.sorted(by: { $0.rawValue < $1.rawValue })
    }

    private func isRefreshDue(id: WidgetID, at now: Date) -> Bool {
        guard let provider = providers[id] else { return false }
        guard let snapshot = snapshots[id] else { return true }
        guard let interval = provider.descriptor.refreshPolicy.interval(for: snapshot.severity) else {
            return false
        }
        guard let lastAttempted = lastAttemptedAt[id] else { return true }

        return now.timeIntervalSince(lastAttempted) >= interval
    }
}

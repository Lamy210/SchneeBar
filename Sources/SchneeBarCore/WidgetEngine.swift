import Foundation

public actor WidgetEngine {
    private var providers: [WidgetID: any WidgetProvider]
    private var snapshots: [WidgetID: WidgetSnapshot] = [:]
    private var lastAttemptedAt: [WidgetID: Date] = [:]
    private var configuration: WidgetConfiguration

    public init(
        providers: [any WidgetProvider] = [],
        configuration: WidgetConfiguration = .init()
    ) {
        self.providers = Dictionary(
            uniqueKeysWithValues: providers.map { ($0.descriptor.id, $0) }
        )
        self.configuration = configuration
    }

    public func register(_ provider: any WidgetProvider) {
        providers[provider.descriptor.id] = provider
    }

    public func unregister(id: WidgetID) {
        providers.removeValue(forKey: id)
        snapshots.removeValue(forKey: id)
        lastAttemptedAt.removeValue(forKey: id)
    }

    public func setConfiguration(_ configuration: WidgetConfiguration) {
        self.configuration = configuration
    }

    public func currentConfiguration() -> WidgetConfiguration {
        configuration
    }

    public func descriptors() -> [WidgetDescriptor] {
        providers.values
            .map(\.descriptor)
            .sorted { lhs, rhs in
                let lhsOrder = configuration.order(for: lhs)
                let rhsOrder = configuration.order(for: rhs)
                if lhsOrder != rhsOrder {
                    return lhsOrder < rhsOrder
                }
                return lhs.id.rawValue < rhs.id.rawValue
            }
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
        for id in orderedEnabledProviderIDs() {
            _ = await refresh(id: id, at: attemptedAt)
        }
        return orderedVisibleSnapshots()
    }

    @discardableResult
    public func refreshDue(at now: Date = .now) async -> [WidgetSnapshot] {
        for id in orderedEnabledProviderIDs() where isRefreshDue(id: id, at: now) {
            _ = await refresh(id: id, at: now)
        }
        return orderedVisibleSnapshots()
    }

    public func secondsUntilNextRefresh(
        at now: Date = .now,
        maximum: TimeInterval = 60
    ) -> TimeInterval {
        let intervals = providers.compactMap { id, provider -> TimeInterval? in
            guard configuration.isEnabled(id) else { return nil }
            guard let lastAttempted = lastAttemptedAt[id] else { return 0 }

            let severity = snapshots[id]?.severity ?? .unavailable
            guard let interval = provider.descriptor.refreshPolicy.interval(for: severity) else {
                return nil
            }

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
            .filter { snapshot in
                configuration.isEnabled(snapshot.descriptor.id) && snapshot.isVisible
            }
            .sorted { lhs, rhs in
                if lhs.priority != rhs.priority {
                    return lhs.priority > rhs.priority
                }

                let lhsOrder = configuration.order(for: lhs.descriptor)
                let rhsOrder = configuration.order(for: rhs.descriptor)
                if lhsOrder != rhsOrder {
                    return lhsOrder < rhsOrder
                }

                return lhs.descriptor.id.rawValue < rhs.descriptor.id.rawValue
            }
    }

    private func orderedEnabledProviderIDs() -> [WidgetID] {
        providers.values
            .map(\.descriptor)
            .filter { configuration.isEnabled($0.id) }
            .sorted { lhs, rhs in
                let lhsOrder = configuration.order(for: lhs)
                let rhsOrder = configuration.order(for: rhs)
                if lhsOrder != rhsOrder {
                    return lhsOrder < rhsOrder
                }
                return lhs.id.rawValue < rhs.id.rawValue
            }
            .map(\.id)
    }

    private func isRefreshDue(id: WidgetID, at now: Date) -> Bool {
        guard configuration.isEnabled(id) else { return false }
        guard let provider = providers[id] else { return false }
        guard let lastAttempted = lastAttemptedAt[id] else { return true }

        let severity = snapshots[id]?.severity ?? .unavailable
        guard let interval = provider.descriptor.refreshPolicy.interval(for: severity) else {
            return false
        }

        return now.timeIntervalSince(lastAttempted) >= interval
    }
}

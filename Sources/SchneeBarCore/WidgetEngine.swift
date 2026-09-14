import Foundation

public actor WidgetEngine {
    private var providers: [WidgetID: any WidgetProvider]
    private var snapshots: [WidgetID: WidgetSnapshot] = [:]
    private var lastAttemptedAt: [WidgetID: Date] = [:]
    private var lastSucceededAt: [WidgetID: Date] = [:]
    private var lastFailureAt: [WidgetID: Date] = [:]
    private var consecutiveFailureCount: [WidgetID: Int] = [:]
    private var providerRevision: [WidgetID: UInt64] = [:]
    private var refreshSequence: [WidgetID: UInt64] = [:]
    private var lastAppliedRefreshSequence: [WidgetID: UInt64] = [:]
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
        let id = provider.descriptor.id
        providers[id] = provider
        invalidateProviderRevision(id: id)
        resetRuntimeState(id: id)
    }

    public func unregister(id: WidgetID) {
        providers.removeValue(forKey: id)
        invalidateProviderRevision(id: id)
        resetRuntimeState(id: id)
    }

    public func setConfiguration(_ configuration: WidgetConfiguration) {
        let previousConfiguration = self.configuration
        self.configuration = configuration

        for (id, provider) in providers {
            let descriptor = provider.descriptor
            let wasEnabled = previousConfiguration.isEnabled(descriptor)
            let isEnabled = configuration.isEnabled(descriptor)
            if !wasEnabled && isEnabled {
                lastAttemptedAt.removeValue(forKey: id)
            }
        }
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
        let providerRevision = providerRevision[id] ?? 0
        let sequence = nextRefreshSequence(id: id)
        lastAttemptedAt[id] = attemptedAt

        do {
            let snapshot = try await provider.snapshot()
            guard isCurrentProviderRevision(providerRevision, id: id),
                  canApplyRefresh(sequence, id: id)
            else {
                return snapshots[id]
            }

            markRefreshApplied(sequence, id: id)
            snapshots[id] = snapshot
            lastSucceededAt[id] = attemptedAt
            consecutiveFailureCount[id] = 0
            return snapshot
        } catch {
            guard isCurrentProviderRevision(providerRevision, id: id),
                  canApplyRefresh(sequence, id: id)
            else {
                return snapshots[id]
            }

            markRefreshApplied(sequence, id: id)
            lastFailureAt[id] = attemptedAt
            consecutiveFailureCount[id, default: 0] += 1

            // Preserve the last known-good value. Provider-specific errors are
            // intentionally discarded; callers can inspect provider-neutral
            // runtime diagnostics instead.
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
            guard configuration.isEnabled(provider.descriptor) else { return nil }
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

    public func diagnostic(id: WidgetID) -> WidgetRuntimeDiagnostic? {
        guard let provider = providers[id] else { return nil }
        return makeDiagnostic(id: id, descriptor: provider.descriptor)
    }

    public func diagnostics() -> [WidgetRuntimeDiagnostic] {
        providers
            .map { id, provider in
                makeDiagnostic(id: id, descriptor: provider.descriptor)
            }
            .sorted { lhs, rhs in
                let lhsOrder = configuration.order(for: lhs.descriptor)
                let rhsOrder = configuration.order(for: rhs.descriptor)
                if lhsOrder != rhsOrder {
                    return lhsOrder < rhsOrder
                }
                return lhs.descriptor.id.rawValue < rhs.descriptor.id.rawValue
            }
    }

    public func orderedVisibleSnapshots() -> [WidgetSnapshot] {
        snapshots.values
            .filter { snapshot in
                configuration.isEnabled(snapshot.descriptor) && snapshot.isVisible
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

    private func makeDiagnostic(
        id: WidgetID,
        descriptor: WidgetDescriptor
    ) -> WidgetRuntimeDiagnostic {
        let failures = consecutiveFailureCount[id, default: 0]
        let hasSnapshot = snapshots[id] != nil
        let health: WidgetRuntimeHealth

        if lastAttemptedAt[id] == nil {
            health = .notLoaded
        } else if failures == 0 {
            health = hasSnapshot ? .healthy : .notLoaded
        } else {
            health = hasSnapshot ? .degraded : .unavailable
        }

        return WidgetRuntimeDiagnostic(
            descriptor: descriptor,
            health: health,
            lastAttemptedAt: lastAttemptedAt[id],
            lastSucceededAt: lastSucceededAt[id],
            lastFailureAt: lastFailureAt[id],
            consecutiveFailureCount: failures,
            isServingLastKnownGood: failures > 0 && hasSnapshot,
            snapshotGeneratedAt: snapshots[id]?.generatedAt
        )
    }

    private func invalidateProviderRevision(id: WidgetID) {
        providerRevision[id] = (providerRevision[id] ?? 0) &+ 1
    }

    private func isCurrentProviderRevision(_ revision: UInt64, id: WidgetID) -> Bool {
        providers[id] != nil && (providerRevision[id] ?? 0) == revision
    }

    private func nextRefreshSequence(id: WidgetID) -> UInt64 {
        let sequence = (refreshSequence[id] ?? 0) &+ 1
        refreshSequence[id] = sequence
        return sequence
    }

    private func canApplyRefresh(_ sequence: UInt64, id: WidgetID) -> Bool {
        sequence > (lastAppliedRefreshSequence[id] ?? 0)
    }

    private func markRefreshApplied(_ sequence: UInt64, id: WidgetID) {
        lastAppliedRefreshSequence[id] = sequence
    }

    private func resetRuntimeState(id: WidgetID) {
        snapshots.removeValue(forKey: id)
        lastAttemptedAt.removeValue(forKey: id)
        lastSucceededAt.removeValue(forKey: id)
        lastFailureAt.removeValue(forKey: id)
        consecutiveFailureCount.removeValue(forKey: id)
        refreshSequence.removeValue(forKey: id)
        lastAppliedRefreshSequence.removeValue(forKey: id)
    }

    private func orderedEnabledProviderIDs() -> [WidgetID] {
        providers.values
            .map(\.descriptor)
            .filter { configuration.isEnabled($0) }
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
        guard let provider = providers[id] else { return false }
        guard configuration.isEnabled(provider.descriptor) else { return false }
        guard let lastAttempted = lastAttemptedAt[id] else { return true }

        let severity = snapshots[id]?.severity ?? .unavailable
        guard let interval = provider.descriptor.refreshPolicy.interval(for: severity) else {
            return false
        }

        return now.timeIntervalSince(lastAttempted) >= interval
    }
}

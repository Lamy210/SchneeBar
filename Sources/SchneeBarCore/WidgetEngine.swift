public actor WidgetEngine {
    private var providers: [WidgetID: any WidgetProvider]
    private var snapshots: [WidgetID: WidgetSnapshot] = [:]

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
    }

    @discardableResult
    public func refresh(id: WidgetID) async -> WidgetSnapshot? {
        guard let provider = providers[id] else { return nil }

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
    public func refreshAll() async -> [WidgetSnapshot] {
        for id in providers.keys.sorted(by: { $0.rawValue < $1.rawValue }) {
            _ = await refresh(id: id)
        }
        return orderedVisibleSnapshots()
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
}

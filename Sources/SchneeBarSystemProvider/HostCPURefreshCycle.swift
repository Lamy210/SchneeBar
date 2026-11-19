import Foundation

/// One iteration of the existing host scheduler. No autonomous task, timer
/// or lease mutation. Call after serialized configuration has settled.
/// Consumers fence their own publication after asynchronous reading.
@MainActor
public enum HostCPURefreshCycle {
    @discardableResult
    public static func run(
        sampler: HostCPUSampler, widget: Bool, companion: Bool,
        force: Bool = false, isCurrent: @MainActor () -> Bool,
        refreshWidget: @MainActor () async -> Void,
        refreshCompanion: @MainActor () async -> Void
    ) async -> Bool {
        await run(plan: { await sampler.refreshPlan() }, widget: widget,
            companion: companion, force: force, isCurrent: isCurrent,
            refreshWidget: refreshWidget, refreshCompanion: refreshCompanion)
    }

    @discardableResult
    static func run(
        plan: @MainActor () async -> HostCPURefreshPlan, widget: Bool, companion: Bool,
        force: Bool = false, isCurrent: @MainActor () -> Bool,
        refreshWidget: @MainActor () async -> Void,
        refreshCompanion: @MainActor () async -> Void
    ) async -> Bool {
        guard !Task.isCancelled, isCurrent() else { return false }
        if widget {
            let snapshot = await plan()
            guard !Task.isCancelled, isCurrent() else { return false }
            if snapshot.consumers.contains(.widget),
               force || snapshot.requiresRefresh(.widget) {
                await refreshWidget()
                guard !Task.isCancelled, isCurrent() else { return false }
            }
        }
        if companion {
            let snapshot = await plan()
            guard !Task.isCancelled, isCurrent() else { return false }
            if snapshot.consumers.contains(.companion),
               force || snapshot.requiresRefresh(.companion) {
                await refreshCompanion()
                guard !Task.isCancelled, isCurrent() else { return false }
            }
        }
        return true
    }
}

import Foundation
@testable import SchneeBarSystemProvider
import Testing

@Test @MainActor func hostCPURefreshCycleReadsPlanAgainForCachedCompanionDelivery() async {
    var actions: [String] = []
    var plans = 0
    let result = await HostCPURefreshCycle.run(plan: {
        plans += 1
        actions.append("plan")
        if plans == 1 {
            return .init(consumers: [.widget, .companion], acquisitionDelay: .zero, pendingDelivery: [])
        }
        return .init(consumers: [.widget, .companion], acquisitionDelay: .seconds(5),
            pendingDelivery: [.companion])
    }, widget: true, companion: true, isCurrent: { true },
        refreshWidget: { actions.append("widget") },
        refreshCompanion: { actions.append("companion") })
    #expect(result)
    #expect(actions == ["plan", "widget", "plan", "companion"])
}

@Test @MainActor func hostCPURefreshCycleRejectsStaleGenerationAfterWidgetAndPlan() async {
    var current = true
    var actions: [String] = []
    let due = HostCPURefreshPlan(consumers: [.widget, .companion], acquisitionDelay: .zero, pendingDelivery: [])
    let first = await HostCPURefreshCycle.run(plan: { actions.append("plan"); return due },
        widget: true, companion: true, isCurrent: { current },
        refreshWidget: { actions.append("widget"); current = false },
        refreshCompanion: { actions.append("companion") })
    #expect(!first && actions == ["plan", "widget"])
    current = true
    actions = []
    let second = await HostCPURefreshCycle.run(plan: {
        actions.append("plan")
        current = false
        return due
    }, widget: true, companion: true, isCurrent: { current },
        refreshWidget: { actions.append("widget") },
        refreshCompanion: { actions.append("companion") })
    #expect(!second && actions == ["plan"])
}

@Test @MainActor func hostCPURefreshCycleSkipsDisabledAndRevokedConsumersEvenWhenForced() async {
    var plans = 0
    var deliveries: [String] = []
    let empty = await HostCPURefreshCycle.run(plan: {
        plans += 1
        return .init(consumers: [], acquisitionDelay: nil, pendingDelivery: [])
    }, widget: false, companion: false, force: true, isCurrent: { true },
        refreshWidget: { deliveries.append("widget") },
        refreshCompanion: { deliveries.append("companion") })
    #expect(empty && plans == 0 && deliveries.isEmpty)
    let revoked = await HostCPURefreshCycle.run(plan: {
        plans += 1
        return .init(consumers: [.widget], acquisitionDelay: .seconds(5), pendingDelivery: [])
    }, widget: true, companion: true, force: true, isCurrent: { true },
        refreshWidget: { deliveries.append("widget") },
        refreshCompanion: { deliveries.append("companion") })
    #expect(revoked && plans == 2 && deliveries == ["widget"])
    let fresh = await HostCPURefreshCycle.run(plan: {
        return .init(consumers: [.widget, .companion], acquisitionDelay: .seconds(5), pendingDelivery: [])
    }, widget: true, companion: true, isCurrent: { true },
        refreshWidget: { deliveries.append("widget") },
        refreshCompanion: { deliveries.append("companion") })
    #expect(fresh && deliveries == ["widget"])
}

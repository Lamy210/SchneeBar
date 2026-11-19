import Foundation
@testable import SchneeBarSystemProvider
import Testing

@Test @MainActor func hostCPUDemandTransitionsPreserveSleepAndWakeOrder() async {
    let sampler = HostCPUSampler()
    let owner = HostCPUDemandTransitions(sampler: sampler)
    var observed: [Set<HostCPUConsumer>] = []
    owner.enqueue(widget: true, companion: false, sleeping: false) {
        let plan = await sampler.refreshPlan()
        observed.append(plan.consumers)
    }
    let sleep = owner.enqueue(widget: true, companion: true, sleeping: true) {
        let plan = await sampler.refreshPlan()
        observed.append(plan.consumers)
    }
    // A cancelled wait handle must not skip a revocation in the FIFO.
    sleep.cancel()
    let wake = owner.enqueue(widget: false, companion: true, sleeping: false) {
        let plan = await sampler.refreshPlan()
        observed.append(plan.consumers)
    }
    await wake.value
    #expect(observed == [Set([.widget]), Set(), Set([.companion])])
    #expect(await sampler.refreshPlan().consumers == [.companion])
    await owner.finish().value
    #expect(await sampler.refreshPlan().consumers.isEmpty)
}

@Test @MainActor func hostCPUDemandTransitionsFinishDrainsAndNeverReopens() async {
    let sampler = HostCPUSampler()
    let owner = HostCPUDemandTransitions(sampler: sampler)
    var afterCalls = 0
    owner.enqueue(widget: true, companion: true, sleeping: false) {
        #expect(await sampler.refreshPlan().consumers == [.widget, .companion])
        afterCalls += 1
    }
    let stopped = owner.finish()
    let late = owner.enqueue(widget: true, companion: true, sleeping: false) {
        afterCalls += 100
    }
    stopped.cancel()
    await late.value
    await owner.finish().value
    #expect(owner.isFinished && afterCalls == 1)
    let plan = await sampler.refreshPlan()
    #expect(plan.consumers.isEmpty && plan.acquisitionDelay == nil)
    do {
        _ = try await sampler.sample(for: .companion)
        Issue.record("Terminal owner must not reopen a lease")
    } catch {
        #expect(error is CancellationError)
    }
}

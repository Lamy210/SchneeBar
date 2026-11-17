import Foundation
import SchneeBarCore
@testable import SchneeBarSystemProvider
import Testing

@Test
func clockWidgetUsesInjectedTimeAndExpectedRefreshPolicy() async throws {
    let fixedDate = Date(timeIntervalSince1970: 1_700_000_000)
    let provider = ClockWidgetProvider(now: { fixedDate })

    let snapshot = try await provider.snapshot()

    #expect(snapshot.descriptor.id == "system.clock")
    #expect(snapshot.generatedAt == fixedDate)
    #expect(snapshot.priority == .background)
    #expect(snapshot.severity == .nominal)
    #expect(snapshot.descriptor.refreshPolicy.interval(for: .nominal) == 30)
    #expect(!snapshot.content(for: .compact).text.isEmpty)
}

@Test
func cpuWidgetProducesBoundedPercentageAndAdaptivePriority() async throws {
    let provider = CPUWidgetProvider()
    let snapshot = try await provider.snapshot()
    let text = snapshot.content(for: .compact).text

    #expect(snapshot.descriptor.id == "system.cpu")
    #expect(snapshot.descriptor.refreshPolicy.interval(for: snapshot.severity) == 5)
    #expect(text.hasSuffix("%"))

    let numeric = text.dropLast()
    let percentage = Int(numeric)
    #expect(percentage != nil)
    if let percentage {
        #expect((0...100).contains(percentage))
    }
}

private func cpuCounters(
    user: UInt32 = 0,
    system: UInt32 = 0,
    idle: UInt32 = 0,
    nice: UInt32 = 0
) -> CPUCounters {
    CPUCounters(user: user, system: system, idle: idle, nice: nice)
}

@Test
func cpuPercentageUsesWholeMachineDeltasNotPerProcessPercentage() throws {
    let baseline = cpuCounters()
    #expect(try cpuCounters(idle: 100).usagePercentage(since: baseline) == 0)
    #expect(try cpuCounters(user: 20, system: 15, idle: 60, nice: 5)
        .usagePercentage(since: baseline) == 40)
    #expect(try cpuCounters(user: 50, idle: 50)
        .usagePercentage(since: baseline) == 50)
    #expect(try cpuCounters(user: 100)
        .usagePercentage(since: baseline) == 100)
}

@Test
func cpuCounterWrapUsesPerStateModuloBeforeAggregation() throws {
    let before = cpuCounters(
        user: UInt32.max - 5,
        system: 7,
        idle: UInt32.max - 10
    )
    let after = cpuCounters(user: 14, system: 17, idle: 29)
    // User wraps by 20, system advances by 10, idle wraps by 40.
    let percentage = try after.usagePercentage(since: before)
    #expect(abs(percentage - (30.0 / 70.0 * 100)) < 0.00001)
}

@Test
func cpuCounterResetDoesNotMasqueradeAsFullCPUUsage() {
    #expect(throws: CPUWidgetError.implausibleCounterDelta) {
        try cpuCounters(user: 5, idle: 5).usagePercentage(
            since: cpuCounters(user: 1_000, idle: 1_000)
        )
    }
}

@Test
func cpuCounterStallDoesNotMasqueradeAsZeroUsage() {
    let baseline = cpuCounters(user: 100, idle: 400)
    #expect(throws: CPUWidgetError.noCounterProgress) {
        try baseline.usagePercentage(since: baseline)
    }
}

private final class ScriptedCPUReader: @unchecked Sendable {
    private let lock = NSLock()
    private let samples: [CPUCounters]
    private var nextIndex = 0

    init(_ samples: [CPUCounters]) {
        self.samples = samples
    }

    func next() throws -> CPUCounters {
        lock.lock()
        defer { lock.unlock() }
        guard nextIndex < samples.count else {
            throw CPUWidgetError.noCounterProgress
        }
        let sample = samples[nextIndex]
        nextIndex += 1
        return sample
    }

    func callCount() -> Int {
        lock.lock()
        defer { lock.unlock() }
        return nextIndex
    }
}

private final class ScriptedCPUClock: @unchecked Sendable {
    private let lock = NSLock()
    private var current: ContinuousClock.Instant

    init(start: ContinuousClock.Instant = ContinuousClock.now) {
        current = start
    }

    func now() -> ContinuousClock.Instant {
        lock.lock()
        defer { lock.unlock() }
        return current
    }

    func advance(by interval: Duration) {
        lock.lock()
        defer { lock.unlock() }
        current = current.advanced(by: interval)
    }
}

@Test
func cpuProviderUsesFiveSecondDeltasAndSystemWideLabel() async throws {
    let samples = ScriptedCPUReader([
        cpuCounters(),
        cpuCounters(user: 20, idle: 80),
        cpuCounters(user: 70, idle: 130),
    ])
    let clock = ScriptedCPUClock()
    let provider = CPUWidgetProvider(
        readCounters: { try samples.next() },
        bootstrapDelay: {},
        now: { clock.now() }
    )

    let initial = try await provider.snapshot()
    #expect(initial.descriptor.displayName == "Total CPU")
    #expect(initial.content(for: .normal).text == "Total CPU 20%")
    clock.advance(by: .seconds(5))
    let next = try await provider.snapshot()
    #expect(next.content(for: .normal).text == "Total CPU 50%")
    #expect(samples.callCount() == 3)
}

@Test
func cpuProviderRebaselinesAfterLongSamplingGap() async throws {
    let samples = ScriptedCPUReader([
        cpuCounters(user: 100, idle: 100),
        cpuCounters(user: 150, idle: 150),
        cpuCounters(user: 250, idle: 300),
        cpuCounters(user: 270, idle: 380),
    ])
    let clock = ScriptedCPUClock()
    let provider = CPUWidgetProvider(
        readCounters: { try samples.next() },
        bootstrapDelay: {},
        now: { clock.now() }
    )

    _ = try await provider.snapshot()
    clock.advance(by: .seconds(31))
    let afterWake = try await provider.snapshot()

    #expect(afterWake.content(for: .normal).text == "Total CPU 20%")
    #expect(samples.callCount() == 4)
}

@Test
func cpuProviderReportsStalledCounterReadingsAsErrorsAndCanRecover() async throws {
    let samples = ScriptedCPUReader([
        cpuCounters(user: 10, idle: 100),
        cpuCounters(user: 10, idle: 100),
        cpuCounters(user: 30, idle: 180),
    ])
    let clock = ScriptedCPUClock()
    let provider = CPUWidgetProvider(
        readCounters: { try samples.next() },
        bootstrapDelay: {},
        now: { clock.now() }
    )

    do {
        _ = try await provider.snapshot()
        Issue.record("A stale CPU counter pair must not render as 0%")
    } catch {
        #expect(error as? CPUWidgetError == .noCounterProgress)
    }

    clock.advance(by: .seconds(5))
    let recovered = try await provider.snapshot()
    #expect(recovered.content(for: .normal).text == "Total CPU 20%")
    #expect(samples.callCount() == 3)
}

/// Explicit handshake keeps concurrent CPU tests independent of CI scheduling.
private actor CPUAsyncGate {
    private var parked = false
    private var parkedWaiter: CheckedContinuation<Void, Never>?
    private var releaseWaiter: CheckedContinuation<Void, Never>?

    func park() async {
        parked = true
        parkedWaiter?.resume()
        parkedWaiter = nil
        await withCheckedContinuation { continuation in
            releaseWaiter = continuation
        }
    }

    func waitUntilParked() async {
        if parked { return }
        await withCheckedContinuation { continuation in
            parkedWaiter = continuation
        }
    }

    func release() {
        releaseWaiter?.resume()
        releaseWaiter = nil
    }
}

private final class CPUJoinProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var joined = false
    private var waiter: CheckedContinuation<Void, Never>?

    func joinedInFlight() {
        lock.lock()
        joined = true
        let oldWaiter = waiter
        waiter = nil
        lock.unlock()
        oldWaiter?.resume()
    }

    func waitUntilJoined() async {
        await withCheckedContinuation { continuation in
            lock.lock()
            if joined {
                lock.unlock()
                continuation.resume()
            } else {
                waiter = continuation
                lock.unlock()
            }
        }
    }
}

@Test
func cpuProviderCoalescesOverlappingInitialSnapshots() async throws {
    let reader = ScriptedCPUReader([
        cpuCounters(),
        cpuCounters(user: 30, idle: 70),
        cpuCounters(user: 45, idle: 155),
    ])
    let clock = ScriptedCPUClock()
    let gate = CPUAsyncGate()
    let probe = CPUJoinProbe()
    let provider = CPUWidgetProvider(
        readCounters: { try reader.next() },
        bootstrapDelay: { await gate.park() },
        now: { clock.now() },
        onJoinInFlight: { probe.joinedInFlight() }
    )

    let first = Task { try await provider.snapshot() }
    await gate.waitUntilParked()
    #expect(reader.callCount() == 1)

    let second = Task { try await provider.snapshot() }
    await probe.waitUntilJoined()
    await gate.release()

    let firstSnapshot = try await first.value
    let secondSnapshot = try await second.value
    #expect(firstSnapshot.content(for: .normal).text == "Total CPU 30%")
    // Both snapshots share the timestamp of the underlying acquisition.
    #expect(secondSnapshot.content(for: .normal) == firstSnapshot.content(for: .normal))
    #expect(reader.callCount() == 2)

    // Once the shared flight completes, the next refresh must read again.
    clock.advance(by: .seconds(5))
    let followUp = try await provider.snapshot()
    #expect(followUp.content(for: .normal).text == "Total CPU 15%")
    #expect(reader.callCount() == 3)
}

@Test
func cpuCancelledWaiterDoesNotInterruptOtherInFlightReader() async throws {
    let reader = ScriptedCPUReader([
        cpuCounters(),
        cpuCounters(user: 20, idle: 80),
    ])
    let clock = ScriptedCPUClock()
    let gate = CPUAsyncGate()
    let probe = CPUJoinProbe()
    let provider = CPUWidgetProvider(
        readCounters: { try reader.next() },
        bootstrapDelay: { await gate.park() },
        now: { clock.now() },
        onJoinInFlight: { probe.joinedInFlight() }
    )

    let active = Task { try await provider.snapshot() }
    await gate.waitUntilParked()
    let cancelled = Task { try await provider.snapshot() }
    await probe.waitUntilJoined()
    cancelled.cancel()
    await gate.release()

    let activeSnapshot = try await active.value
    _ = await cancelled.result
    #expect(activeSnapshot.content(for: .normal).text == "Total CPU 20%")
    #expect(reader.callCount() == 2)
}

@Test
func sharedCPUConsumersReuseSampleAndCachedWindow() async throws {
    let reader = ScriptedCPUReader([
        cpuCounters(), cpuCounters(user: 30, idle: 70),
        cpuCounters(user: 80, idle: 120)
    ])
    let clock = ScriptedCPUClock()
    let sampler = HostCPUSampler(
        readCounters: { try reader.next() }, bootstrapDelay: {}, now: { clock.now() }
    )
    let widget = await sampler.subscribe(.widget)
    let companion = await sampler.subscribe(.companion)
    let provider = CPUWidgetProvider(sampler: sampler, lease: widget)
    let first = try await sampler.sample(for: companion)
    clock.advance(by: .seconds(1))
    let snapshot = try await provider.snapshot()
    let cached = try await sampler.sample(for: companion)
    #expect(snapshot.content(for: .normal).text == "Total CPU 30%")
    #expect(snapshot.generatedAt == first.wallTime)
    #expect(first == cached)
    #expect(reader.callCount() == 2)

    clock.advance(by: .seconds(4))
    let next = try await sampler.sample(for: companion)
    #expect(next.id != first.id)
    #expect(next.epoch == first.epoch)
    #expect(next.percentage == 50)
    #expect(reader.callCount() == 3)
}

@Test
func sharedCPUFinalUnsubscribeInvalidatesParkedBootstrap() async throws {
    let reader = ScriptedCPUReader([
        cpuCounters(), cpuCounters(user: 100, idle: 100),
        cpuCounters(user: 120, idle: 180)
    ])
    let clock = ScriptedCPUClock()
    let gate = CPUAsyncGate()
    // Only the first bootstrap uses the gate.
    let sampler = HostCPUSampler(
        readCounters: { try reader.next() },
        bootstrapDelay: {
            if reader.callCount() == 1 { await gate.park() }
        },
        now: { clock.now() }
    )
    let old = await sampler.subscribe(.widget)
    let pending = Task { try await sampler.sample(for: old) }
    await gate.waitUntilParked()
    await sampler.unsubscribe(old)
    let fresh = await sampler.subscribe(.widget)
    #expect(fresh != old)
    let valid = try await sampler.sample(for: fresh)
    #expect(valid.percentage == 20)
    await gate.release()
    do {
        _ = try await pending.value
        Issue.record("Invalidated bootstrap delivered a result")
    } catch {
        #expect(error is CancellationError)
    }
    #expect(reader.callCount() == 3)
    await sampler.unsubscribe(old)
    let current = try await sampler.sample(for: fresh)
    #expect(current == valid)
}

@Test
func sharedCPUSuspendAndResumeRebaselineEvenForShortSleep() async throws {
    let reader = ScriptedCPUReader([
        cpuCounters(), cpuCounters(user: 20, idle: 80),
        cpuCounters(user: 200, idle: 200), cpuCounters(user: 240, idle: 260)
    ])
    let clock = ScriptedCPUClock()
    let sampler = HostCPUSampler(
        readCounters: { try reader.next() }, bootstrapDelay: {}, now: { clock.now() }
    )
    let widget = await sampler.subscribe(.widget)
    let companion = await sampler.subscribe(.companion)
    let initial = try await sampler.sample(for: widget)
    await sampler.unsubscribe(widget)
    let stillActive = try await sampler.sample(for: companion)
    #expect(stillActive == initial)
    await sampler.suspend()
    do {
        _ = try await sampler.sample(for: companion)
        Issue.record("Suspended sampler returned a cached value")
    } catch {
        #expect(error is CancellationError)
    }
    await sampler.resume()
    let afterWake = try await sampler.sample(for: companion)
    #expect(afterWake.epoch != initial.epoch)
    #expect(afterWake.percentage == 40)
    #expect(reader.callCount() == 4)
}

@Test
func sharedCPUFailureIsNotZeroAndIsCoalescedWithinWindow() async throws {
    let reader = ScriptedCPUReader([
        cpuCounters(user: 10, idle: 10), cpuCounters(user: 10, idle: 10),
        cpuCounters(user: 20, idle: 50)
    ])
    let clock = ScriptedCPUClock()
    let sampler = HostCPUSampler(
        readCounters: { try reader.next() }, bootstrapDelay: {}, now: { clock.now() }
    )
    let widget = await sampler.subscribe(.widget)
    let companion = await sampler.subscribe(.companion)
    for lease in [widget, companion] {
        do {
            _ = try await sampler.sample(for: lease)
            Issue.record("Counter stall was reported as a valid sample")
        } catch {
            #expect(error as? CPUWidgetError == .noCounterProgress)
        }
    }
    #expect(reader.callCount() == 2)
    clock.advance(by: .seconds(5))
    let recovered = try await sampler.sample(for: companion)
    #expect(recovered.percentage == 20)
    #expect(reader.callCount() == 3)
}

@Test
func managedDemandDoesNotReadWhenDisabledAndRebaselinesOnEnable() async throws {
    let reader = ScriptedCPUReader([
        cpuCounters(), cpuCounters(user: 10, idle: 90),
        cpuCounters(user: 100, idle: 100), cpuCounters(user: 160, idle: 140)
    ])
    let clock = ScriptedCPUClock()
    let sampler = HostCPUSampler(
        readCounters: { try reader.next() }, bootstrapDelay: {}, now: { clock.now() }
    )
    let provider = CPUWidgetProvider(sampler: sampler)
    await sampler.reconcileDemand(widget: false, companion: false, sleeping: false)
    do {
        _ = try await provider.snapshot()
        Issue.record("Disabled widget must not sample")
    } catch { #expect(error is CancellationError) }
    #expect(reader.callCount() == 0)
    await sampler.reconcileDemand(widget: true, companion: false, sleeping: false)
    let initial = try await sampler.sample(for: HostCPUConsumer.widget)
    #expect(initial.percentage == 10)
    await sampler.reconcileDemand(widget: false, companion: false, sleeping: false)
    await sampler.reconcileDemand(widget: true, companion: false, sleeping: false)
    let latest = try await sampler.sample(for: HostCPUConsumer.widget)
    #expect(latest.percentage == 60)
    #expect(latest.epoch != initial.epoch)
    #expect(reader.callCount() == 4)
}

@Test
func managedDemandCanSwitchConsumersWithoutAdditionalRead() async throws {
    let reader = ScriptedCPUReader([cpuCounters(), cpuCounters(user: 25, idle: 75)])
    let clock = ScriptedCPUClock()
    let sampler = HostCPUSampler(
        readCounters: { try reader.next() }, bootstrapDelay: {}, now: { clock.now() }
    )
    await sampler.reconcileDemand(widget: true, companion: true, sleeping: false)
    let first = try await sampler.sample(for: HostCPUConsumer.widget)
    await sampler.reconcileDemand(widget: false, companion: true, sleeping: false)
    let stillActive = try await sampler.sample(for: HostCPUConsumer.companion)
    #expect(stillActive == first)
    do {
        _ = try await sampler.sample(for: HostCPUConsumer.widget)
        Issue.record("Removed consumer must not sample")
    } catch { #expect(error is CancellationError) }
    #expect(reader.callCount() == 2)
}

@Test func cpuAcquisitionDeadlineUsesCaptureNotAttemptAndSharedFailureWindow() async throws {
    let reader = ScriptedCPUReader([
        cpuCounters(), cpuCounters(user: 10, idle: 90),
        cpuCounters(user: 20, idle: 180), cpuCounters(user: 20, idle: 180)
    ])
    let clock = ScriptedCPUClock()
    let sampler = HostCPUSampler(
        readCounters: { try reader.next() },
        bootstrapDelay: { clock.advance(by: .milliseconds(500)) },
        now: { clock.now() }
    )
    #expect(await sampler.delayUntilNextAcquisition(for: .widget) == nil)
    await sampler.reconcileDemand(widget: true, companion: true, sleeping: false)
    #expect(await sampler.delayUntilNextAcquisition(for: .widget) == .zero)
    let initial = try await sampler.sample(for: HostCPUConsumer.widget)
    clock.advance(by: .milliseconds(4500))
    #expect(await sampler.delayUntilNextAcquisition(for: .widget) == .milliseconds(500))
    #expect(await sampler.delayUntilNextAcquisition(for: .companion) == .milliseconds(500))
    let cached = try await sampler.sample(for: HostCPUConsumer.companion)
    #expect(cached == initial)
    #expect(reader.callCount() == 2)
    clock.advance(by: .milliseconds(500))
    #expect(await sampler.delayUntilNextAcquisition(for: .widget) == .zero)
    let fresh = try await sampler.sample(for: HostCPUConsumer.widget)
    #expect(fresh.id != initial.id)
    #expect(reader.callCount() == 3)
    clock.advance(by: .seconds(5))
    do {
        _ = try await sampler.sample(for: HostCPUConsumer.widget)
        Issue.record("Expected stalled counters")
    } catch { #expect(error as? CPUWidgetError == .noCounterProgress) }
    #expect(await sampler.delayUntilNextAcquisition(for: .companion) == .seconds(5))
    await sampler.reconcileDemand(widget: false, companion: false, sleeping: true)
    #expect(await sampler.delayUntilNextAcquisition(for: .widget) == nil)
    await sampler.reconcileDemand(widget: true, companion: false, sleeping: false)
    #expect(await sampler.delayUntilNextAcquisition(for: .widget) == .zero)
}


@Test func sharedCPURefreshPlanTracksBothConsumersAndFreshDeadline() async throws {
    let reader = ScriptedCPUReader([
        cpuCounters(), cpuCounters(user: 30, idle: 70),
        cpuCounters(user: 80, idle: 120)
    ])
    let clock = ScriptedCPUClock()
    let sampler = HostCPUSampler(readCounters: { try reader.next() },
        bootstrapDelay: {}, now: { clock.now() })

    let idle = await sampler.refreshPlan()
    #expect(idle.consumers.isEmpty && idle.acquisitionDelay == nil)
    #expect(idle.nextHostDelay(otherWidgetsSeconds: 0) == .seconds(1))
    #expect(idle.nextHostDelay(otherWidgetsSeconds: 60) == .seconds(30))
    #expect(!idle.isDue(.widget) && !idle.isDue(.companion))

    await sampler.reconcileDemand(widget: false, companion: true, sleeping: false)
    let companionOnly = await sampler.refreshPlan()
    #expect(companionOnly.consumers == [.companion])
    #expect(companionOnly.isDue(.companion) && !companionOnly.isDue(.widget))
    #expect(companionOnly.nextHostDelay(otherWidgetsSeconds: 30) == .milliseconds(50))

    let first = try await sampler.sample(for: HostCPUConsumer.companion)
    await sampler.reconcileDemand(widget: true, companion: true, sleeping: false)
    let both = await sampler.refreshPlan()
    #expect(both.consumers == [.widget, .companion])
    #expect(both.acquisitionDelay == .seconds(5))
    #expect(!both.isDue(.widget) && !both.isDue(.companion))
    let cached = try await sampler.sample(for: HostCPUConsumer.widget)
    #expect(cached == first && reader.callCount() == 2)

    clock.advance(by: .milliseconds(4750))
    let remainder = await sampler.refreshPlan()
    #expect(remainder.nextHostDelay(otherWidgetsSeconds: 0) == .milliseconds(250))
    clock.advance(by: .milliseconds(250))
    let due = await sampler.refreshPlan()
    #expect(due.isDue(.widget) && due.isDue(.companion))
    let fresh = try await sampler.sample(for: HostCPUConsumer.widget)
    #expect(fresh.id != first.id && reader.callCount() == 3)

    await sampler.reconcileDemand(widget: true, companion: false, sleeping: false)
    let widgetOnly = await sampler.refreshPlan()
    #expect(widgetOnly.consumers == [.widget] && widgetOnly.acquisitionDelay == .seconds(5))
    await sampler.reconcileDemand(widget: false, companion: false, sleeping: true)
    #expect(await sampler.refreshPlan() == idle)
    #expect(reader.callCount() == 3)
}

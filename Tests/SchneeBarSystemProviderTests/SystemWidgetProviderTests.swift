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
    #expect(secondSnapshot == firstSnapshot)
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

import Foundation
@testable import SchneeBarCompanionPreview
import SchneeBarCompanionCore
@testable import SchneeBarSystemProvider
import Testing

private final class PreviewCounterFixture: @unchecked Sendable {
    private let lock = NSLock()
    private var calls: UInt32 = 0
    func read() -> CPUCounters {
        lock.lock()
        defer { lock.unlock() }
        calls += 100
        return CPUCounters(user: calls, system: 0, idle: 0, nice: 0)
    }
}

@MainActor
private func modelFixture() -> (CompanionPreviewModel, HostCPUSampler) {
    let counter = PreviewCounterFixture()
    let sampler = HostCPUSampler(
        readCounters: { counter.read() }, bootstrapDelay: {},
        now: { ContinuousClock.now }
    )
    return (CompanionPreviewModel(
        sampler: sampler, isBarRunning: { false }, makeStatusItem: { nil },
        systemReduceMotion: { false }, allowHeadlessPresentation: true
    ), sampler)
}

@MainActor
private func waitForPreview(_ condition: @MainActor () async -> Bool) async throws {
    let deadline = ContinuousClock.now.advanced(by: .seconds(3))
    while !(await condition()) {
        guard ContinuousClock.now < deadline else {
            Issue.record("Preview condition did not become true")
            throw CancellationError()
        }
        try await Task.sleep(for: .milliseconds(10))
    }
}

@Test @MainActor func unrelatedCPUVisibilityPreservesAutomaticReaction() async throws {
    let (model, sampler) = modelFixture()
    model.start()
    defer { model.stop() }
    try await waitForPreview { model.state == .sprint }
    #expect(model.effectiveRate == 2)
    model.showCPU = true
    // Reconciliation itself must not briefly replace the current state.
    #expect(model.state == .sprint)
    #expect(model.effectiveRate == 2)
    try await waitForPreview { !model.cpuText.isEmpty }
    #expect(model.state == .sprint)
    model.showCPU = false
    #expect(model.state == .sprint)
    #expect(model.cpuText.isEmpty)
    try await waitForPreview {
        await sampler.delayUntilNextAcquisition(for: .widget) == nil
    }
    model.stop()
    try await waitForPreview {
        await sampler.delayUntilNextAcquisition(for: .companion) == nil
    }
    #expect(!model.started)
}

@Test @MainActor func modelDeallocationRevokesDemandWithoutExplicitStop() async throws {
    let counters = PreviewCounterFixture()
    let sampler = HostCPUSampler(
        readCounters: { counters.read() }, bootstrapDelay: {},
        now: { ContinuousClock.now }
    )
    var model: CompanionPreviewModel? = CompanionPreviewModel(
        sampler: sampler, isBarRunning: { false }, makeStatusItem: { nil },
        systemReduceMotion: { false }, allowHeadlessPresentation: true
    )
    weak var released = model
    model?.start()
    try await waitForPreview { model?.state == .sprint }
    // No explicit Stop: the idle task must not retain its owner.
    model = nil
    try await waitForPreview { released == nil }
    try await waitForPreview {
        await sampler.delayUntilNextAcquisition(for: .companion) == nil
    }
    #expect(released == nil)
}

/// Monotonic clock and requested delays are controlled independently of the
/// host's real CPU ticks. The sleeper records each deadline then suspends
/// with a cancellation-cooperative sleep; tests never wait five real seconds.
private final class PreviewDeadlineFixture: @unchecked Sendable {
    private let lock = NSLock()
    private var instant = ContinuousClock.now
    private var waits: [Duration] = []

    func now() -> ContinuousClock.Instant {
        lock.lock()
        defer { lock.unlock() }
        return instant
    }

    func advance(_ duration: Duration) {
        lock.lock()
        defer { lock.unlock() }
        instant = instant.advanced(by: duration)
    }

    func record(_ duration: Duration) {
        lock.lock()
        defer { lock.unlock() }
        waits.append(duration)
    }

    func recorded() -> [Duration] {
        lock.lock()
        defer { lock.unlock() }
        return waits
    }
}

@Test @MainActor func previewVisibilityChangeSchedulesOnlyRemainingCacheWindow() async throws {
    let counters = PreviewCounterFixture()
    let clock = PreviewDeadlineFixture()
    let sampler = HostCPUSampler(
        readCounters: { counters.read() },
        bootstrapDelay: { clock.advance(.milliseconds(500)) },
        now: { clock.now() }
    )
    let model = CompanionPreviewModel(
        sampler: sampler, isBarRunning: { false }, makeStatusItem: { nil },
        systemReduceMotion: { false }, allowHeadlessPresentation: true,
        waitForNextPoll: { duration in
            clock.record(duration)
            try await Task.sleep(for: .seconds(60))
        }
    )
    model.start()
    defer { model.stop() }
    try await waitForPreview { clock.recorded().count == 1 }
    #expect(clock.recorded() == [.seconds(5)])
    clock.advance(.milliseconds(4500))
    model.showCPU = true
    try await waitForPreview { clock.recorded().count == 2 }
    #expect(clock.recorded() == [.seconds(5), .milliseconds(500)])
    #expect(model.state == .sprint)
    model.stop()
    try await waitForPreview {
        let widget = await sampler.delayUntilNextAcquisition(for: .widget)
        let companion = await sampler.delayUntilNextAcquisition(for: .companion)
        return widget == nil && companion == nil
    }
}

@Test @MainActor func failedStatusSurfaceDoesNotStartOrAcquire() async throws {
    let counters = PreviewCounterFixture()
    let sampler = HostCPUSampler(
        readCounters: { counters.read() }, bootstrapDelay: {},
        now: { ContinuousClock.now }
    )
    let model = CompanionPreviewModel(
        sampler: sampler, isBarRunning: { false }, makeStatusItem: { nil },
        systemReduceMotion: { false }
    )
    model.start()
    #expect(!model.started)
    #expect(!model.message.isEmpty)
    #expect(await sampler.delayUntilNextAcquisition(for: .widget) == nil)
    #expect(await sampler.delayUntilNextAcquisition(for: .companion) == nil)
}

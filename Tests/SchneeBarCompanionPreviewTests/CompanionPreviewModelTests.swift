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
        systemReduceMotion: { false }
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
        systemReduceMotion: { false }
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

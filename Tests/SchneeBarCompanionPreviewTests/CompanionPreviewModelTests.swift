import Foundation
@testable import SchneeBarCompanionPreview
import SchneeBarCompanionAssets
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
        sampler: sampler, conflictingApplication: { nil }, makeStatusItem: { nil },
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
        sampler: sampler, conflictingApplication: { nil }, makeStatusItem: { nil },
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
        sampler: sampler, conflictingApplication: { nil }, makeStatusItem: { nil },
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
        sampler: sampler, conflictingApplication: { nil }, makeStatusItem: { nil },
        systemReduceMotion: { false }
    )
    model.start()
    #expect(!model.started)
    #expect(!model.message.isEmpty)
    #expect(await sampler.delayUntilNextAcquisition(for: .widget) == nil)
    #expect(await sampler.delayUntilNextAcquisition(for: .companion) == nil)
}

@Test @MainActor func previewRefusesKnownApplicationConflictAtStart() async {
    for conflict in ["SchneeBar", "SchneeRunner", "another Companion Preview"] {
        let sampler = HostCPUSampler()
        let model = CompanionPreviewModel(
            sampler: sampler, conflictingApplication: { conflict },
            makeStatusItem: { nil }, systemReduceMotion: { false },
            allowHeadlessPresentation: true
        )
        model.start()
        #expect(!model.started)
        #expect(model.message.contains(conflict))
        #expect(await sampler.delayUntilNextAcquisition(for: .widget) == nil)
        #expect(await sampler.delayUntilNextAcquisition(for: .companion) == nil)
    }
}

@MainActor
private final class PreviewConflictFixture {
    var application: String?
}

@Test @MainActor func launchAndWakeConflictsStopPreviewWithoutRenewingDemand() async throws {
    let counters = PreviewCounterFixture()
    let sampler = HostCPUSampler(
        readCounters: { counters.read() }, bootstrapDelay: {},
        now: { ContinuousClock.now }
    )
    let conflict = PreviewConflictFixture()
    let model = CompanionPreviewModel(
        sampler: sampler, conflictingApplication: { conflict.application },
        makeStatusItem: { nil }, systemReduceMotion: { false },
        allowHeadlessPresentation: true
    )
    model.start()
    defer { model.stop() }
    try await waitForPreview { model.state == .sprint }
    conflict.application = "SchneeRunner"
    model.appLaunched()
    #expect(!model.started)
    #expect(model.message.contains("SchneeRunner"))
    try await waitForPreview {
        await sampler.delayUntilNextAcquisition(for: .companion) == nil
    }

    conflict.application = nil
    model.start()
    try await waitForPreview { model.state == .sprint }
    model.setSleeping(true)
    try await waitForPreview {
        await sampler.delayUntilNextAcquisition(for: .companion) == nil
    }
    conflict.application = "SchneeBar"
    model.setSleeping(false)
    #expect(!model.started)
    #expect(model.message.contains("SchneeBar"))
    #expect(await sampler.delayUntilNextAcquisition(for: .companion) == nil)
}

@Test @MainActor func selectedImageFailurePreservesLastSuccessAndRestoreDefault() async throws {
    let (model, _) = modelFixture()
    model.automatic = false
    model.freeze = true
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("preview-import-\(UUID())", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
    defer { try? FileManager.default.removeItem(at: directory) }
    let image = directory.appendingPathComponent("valid.gif")
    let bytes = try #require(Data(base64Encoded: "R0lGODlhBAACAIEAAECA/wAAAAAAAAAAACH/C05FVFNDQVBFMi4wAwEAAAAh+QQACgAAACwAAAAABAACAAAIBwABCBwoMCAAIfkEARQAAQAsAAAAAAQAAgCB/0AAAAAAAAAAAAAACAcAAQgcKDAgADs="))
    try bytes.write(to: image)
    let invalid = directory.appendingPathComponent("invalid.gif")
    try Data([0, 1, 2]).write(to: invalid)
    model.start()
    defer { model.stop() }
    let session = try #require(model.imageSelectionSession)
    model.importImage(image, session: session)
    try await waitForPreview { !model.imageImportPending }
    #expect(model.imageSource == .selectedFile)
    model.importImage(invalid, session: session)
    try await waitForPreview { !model.imageImportPending }
    #expect(model.imageSource == .selectedFile)
    #expect(model.imageMessage.contains("retained"))
    model.restoreBuiltInImage()
    #expect(model.imageSource == .builtIn)
    #expect(!model.imageImportPending)
}

/// A selected image is still decoding while the preview is stopped. The same
/// queue must retain its worker slot across stop/restart, but publish nothing.
private final class PreviewImportGate: @unchecked Sendable {
    private let lock = NSLock()
    private let releaseGate = DispatchSemaphore(value: 0)
    private var count = 0
    func work(_ url: URL) throws -> CompanionAssetCatalog {
        lock.lock()
        count += 1
        let first = count == 1
        lock.unlock()
        if first, releaseGate.wait(timeout: .now() + 5) != .success {
            throw CancellationError()
        }
        return try CompanionPreviewAssets.catalogue()
    }
    func calls() -> Int {
        lock.lock()
        defer { lock.unlock() }
        return count
    }
    func release() { releaseGate.signal() }
}

@Test @MainActor func stopRestartFencesPickerAndLateImportWithoutSecondWorker() async throws {
    let gate = PreviewImportGate()
    defer { gate.release() }
    let queue = CompanionImportQueue<URL, CompanionAssetCatalog>(work: { try gate.work($0) })
    let model = CompanionPreviewModel(
        conflictingApplication: { nil }, makeStatusItem: { nil },
        systemReduceMotion: { true }, allowHeadlessPresentation: true,
        imageQueue: queue
    )
    model.start()
    defer { model.stop() }
    let first = try #require(model.imageSelectionSession)
    let url = URL(fileURLWithPath: "/fixture-only.gif")
    model.importImage(url, session: first)
    try await waitForPreview { gate.calls() == 1 }
    model.stop()
    #expect(model.imageSelectionSession == nil)
    #expect(!model.imageImportPending)
    #expect(queue.isBusy)
    model.start()
    let second = try #require(model.imageSelectionSession)
    #expect(first != second)
    model.importImage(url, session: first)
    #expect(!model.imageImportPending)
    model.importImage(url, session: second)
    #expect(model.imageImportPending)
    #expect(gate.calls() == 1)
    gate.release()
    try await waitForPreview { !model.imageImportPending }
    #expect(gate.calls() == 2)
    #expect(model.imageSource == .selectedFile)
    model.showCharacter = false
    #expect(model.imageSelectionSession == nil)
    model.showCharacter = true
    let third = try #require(model.imageSelectionSession)
    #expect(third != second)
    model.setSleeping(true)
    #expect(model.imageSelectionSession == nil)
    model.setSleeping(false)
    #expect(model.imageSelectionSession != third)
    model.stop()
    #expect(model.imageSource == .builtIn)
}

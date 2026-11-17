import Foundation
@testable import SchneeBarCompanionPreview
import SchneeBarCompanionAssets
import SchneeBarCompanionEvents
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

@Test @MainActor func localNotificationOptInFencesLifecycleAndPublishesExpiry() async throws {
    let (model, _) = modelFixture()
    model.automatic = false
    model.freeze = true
    model.start()
    defer { model.stop() }
    #expect(model.localNotificationSession == nil)
    model.listenToLocalEvents = true
    let first = try #require(model.localNotificationSession)
    #expect(model.receiveLocalNotification(session: first, kind: .build,
        object: "{\"phase\":\"started\"}") == .accepted)
    #expect(model.state == .dash)
    model.showCharacter = false
    #expect(model.localNotificationSession == nil)
    model.showCharacter = true
    let second = try #require(model.localNotificationSession)
    #expect(first != second)
    #expect(model.state == .run)
    #expect(model.receiveLocalNotification(session: first, kind: .build,
        object: "{\"phase\":\"started\"}") == nil)
    #expect(model.receiveLocalNotification(session: second, kind: .character,
        object: "{\"action\":\"set\",\"state\":\"sprint\",\"durationSeconds\":0.1}") == .accepted)
    #expect(model.state == .sprint)
    try await waitForPreview { model.state == .run }
    model.listenToLocalEvents = false
    #expect(model.localNotificationSession == nil)
}

@Test @MainActor func notificationPayloadBoundsUTF8AndRejectsNonString() {
    func outcome(_ object: Any?) -> Int {
        switch PreviewLocalNotificationSubscription.boundedPayload(object) {
        case .bytes(let data): return data.count
        case .oversized: return -1
        case .malformed: return -2
        }
    }
    #expect(outcome(String(repeating: "a", count: 4096)) == 4096)
    #expect(outcome(String(repeating: "a", count: 4097)) == -1)
    #expect(outcome(String(repeating: "あ", count: 1366)) == -1)
    #expect(outcome(42) == -2)
    #expect(outcome(nil) == -2)
}

@Test @MainActor func previewLibraryImportSelectAndRestartRestore() async throws {
    let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    let source = tmp.appendingPathComponent("fixture.schneerunner", isDirectory: true)
    let root = tmp.appendingPathComponent("preview-owned", isDirectory: true)
    try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tmp) }
    let gif = try #require(Data(base64Encoded: "R0lGODlhBAACAIEAAECA/wAAAAAAAAAAACH/C05FVFNDQVBFMi4wAwEAAAAh+QQACgAAACwAAAAABAACAAAIBwABCBwoMCAAIfkEARQAAQAsAAAAAAQAAgCB/0AAAAAAAAAAAAAACAcAAQgcKDAgADs="))
    try gif.write(to: source.appendingPathComponent("run.gif"))
    try Data(#"{"formatVersion":1,"name":"Preview fixture","defaultState":"run","clips":[{"state":"run","kind":"gif","path":"run.gif"}]}"#.utf8)
        .write(to: source.appendingPathComponent("character.json"))
    let model = CompanionPreviewModel(conflictingApplication: { nil }, makeStatusItem: { nil },
        systemReduceMotion: { true }, allowHeadlessPresentation: true, libraryRoot: root)
    #expect(!FileManager.default.fileExists(atPath: root.path))
    model.start()
    defer { model.stop() }
    try await waitForPreview { !model.libraryBusy && model.libraryInventory != nil }
    #expect(model.imageSource == .builtIn)
    model.importPack(source)
    try await waitForPreview { !model.libraryBusy }
    let id = try #require(model.libraryInventory?.entries.first?.id)
    #expect(model.imageSource == .builtIn)
    model.selectPack(id)
    try await waitForPreview { !model.libraryBusy }
    #expect(model.imageSource == .installedPack(id))
    model.stop()
    #expect(model.imageSource == .builtIn)
    model.start()
    try await waitForPreview { !model.libraryBusy }
    #expect(model.imageSource == .installedPack(id))
    model.selectLibraryDefault()
    try await waitForPreview { !model.libraryBusy }
    #expect(model.imageSource == .builtIn)
    model.stop()
    model.start()
    try await waitForPreview { !model.libraryBusy }
    #expect(model.imageSource == .builtIn)
}

@Test @MainActor func previewLibraryCannotOverlapCancellationResistantImageWorker() async throws {
    let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: false)
    defer { try? FileManager.default.removeItem(at: tmp) }
    let gate = PreviewImportGate()
    defer { gate.release() }
    let queue = CompanionImportQueue<URL, CompanionAssetCatalog>(work: { try gate.work($0) })
    let model = CompanionPreviewModel(conflictingApplication: { nil }, makeStatusItem: { nil },
        systemReduceMotion: { true }, allowHeadlessPresentation: true, imageQueue: queue,
        libraryRoot: tmp.appendingPathComponent("owned"))
    model.start()
    defer { model.stop() }
    try await waitForPreview { !model.libraryBusy }
    let session = try #require(model.imageSelectionSession)
    model.importImage(URL(fileURLWithPath: "/fixture-only.gif"), session: session)
    try await waitForPreview { gate.calls() == 1 }
    model.restoreBuiltInImage()
    #expect(queue.isBusy)
    #expect(!model.imageImportPending)
    model.refreshLibrary()
    #expect(!model.libraryBusy)
    #expect(model.libraryMessage.contains("worker still finishing"))
    gate.release()
    try await waitForPreview { !queue.isBusy }
    model.refreshLibrary()
    try await waitForPreview { !model.libraryBusy && model.libraryInventory != nil }
}

@Test @MainActor func previewTrashRestorePurgeAndStaleConfirmation() async throws {
    let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    let source = tmp.appendingPathComponent("fixture.schneerunner", isDirectory: true)
    let root = tmp.appendingPathComponent("owned", isDirectory: true)
    try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tmp) }
    let gif = try #require(Data(base64Encoded: "R0lGODlhBAACAIEAAECA/wAAAAAAAAAAACH/C05FVFNDQVBFMi4wAwEAAAAh+QQACgAAACwAAAAABAACAAAIBwABCBwoMCAAIfkEARQAAQAsAAAAAAQAAgCB/0AAAAAAAAAAAAAACAcAAQgcKDAgADs="))
    try gif.write(to: source.appendingPathComponent("run.gif"))
    try Data(#"{"formatVersion":1,"name":"Trash fixture","defaultState":"run","clips":[{"state":"run","kind":"gif","path":"run.gif"}]}"#.utf8)
        .write(to: source.appendingPathComponent("character.json"))
    let model = CompanionPreviewModel(conflictingApplication: { nil }, makeStatusItem: { nil },
        systemReduceMotion: { true }, allowHeadlessPresentation: true, libraryRoot: root)
    model.start()
    defer { model.stop() }
    try await waitForPreview { !model.libraryBusy && model.libraryInventory != nil }
    model.importPack(source)
    try await waitForPreview { !model.libraryBusy }
    let id = try #require(model.libraryInventory?.entries.first?.id)
    model.selectPack(id)
    try await waitForPreview { !model.libraryBusy }
    #expect(model.imageSource == .installedPack(id))
    let stale = try #require(model.recoveryConfirmation(.trash(id)))
    model.showCharacter = false
    model.showCharacter = true
    model.confirmRecovery(stale)
    #expect(!model.libraryBusy)
    #expect(model.imageSource == .installedPack(id))
    let confirmation = try #require(model.recoveryConfirmation(.trash(id)))
    model.confirmRecovery(confirmation)
    #expect(model.imageSource == .builtIn)
    try await waitForPreview { !model.libraryBusy }
    #expect(model.libraryInventory?.trashedIDs == [id])
    #expect(model.recoveryConfirmation(.trash(id)) == nil)
    let restore = try #require(model.recoveryConfirmation(.restore(id)))
    model.confirmRecovery(restore)
    try await waitForPreview { !model.libraryBusy }
    #expect(model.imageSource == .builtIn)
    model.restoreSavedChoice()
    try await waitForPreview { !model.libraryBusy }
    #expect(model.imageSource == .builtIn)
    model.confirmRecovery(try #require(model.recoveryConfirmation(.trash(id))))
    try await waitForPreview { !model.libraryBusy }
    model.confirmRecovery(try #require(model.recoveryConfirmation(.purge(id))))
    try await waitForPreview { !model.libraryBusy }
    #expect(model.libraryInventory?.trashedIDs.isEmpty == true)
    #expect(model.libraryInventory?.entries.isEmpty == true)
    #expect(try Data(contentsOf: source.appendingPathComponent("run.gif")) == gif)
}

@Test @MainActor func previewRecoveryOnlyDiscardsConfirmedGeneratedEntries() async throws {
    let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    let root = tmp.appendingPathComponent("owned", isDirectory: true)
    let fm = FileManager.default
    try fm.createDirectory(at: tmp, withIntermediateDirectories: false)
    defer { try? fm.removeItem(at: tmp) }
    let model = CompanionPreviewModel(conflictingApplication: { nil }, makeStatusItem: { nil },
        systemReduceMotion: { true }, allowHeadlessPresentation: true, libraryRoot: root)
    model.start()
    defer { model.stop() }
    try await waitForPreview { !model.libraryBusy && model.libraryInventory != nil }
    let id = UUID()
    let stage = root.appendingPathComponent(".stage-" + id.uuidString.lowercased(), isDirectory: true)
    try fm.createDirectory(at: stage, withIntermediateDirectories: false,
                           attributes: [.posixPermissions: NSNumber(value: 0o700)])
    let pending = root.appendingPathComponent(".selection-pending")
    try #require(fm.createFile(atPath: pending.path, contents: Data([1]),
                              attributes: [.posixPermissions: NSNumber(value: 0o600)]))
    let unknown = root.appendingPathComponent("unrelated")
    try Data([9]).write(to: unknown)
    model.refreshLibrary()
    try await waitForPreview { !model.libraryBusy }
    #expect(model.libraryInventory?.pendingSelectionRecovery == true)
    #expect(model.libraryInventory?.unknownEntryCount == 1)
    #expect(model.libraryInventory?.canInstall == false)
    model.confirmRecovery(try #require(model.recoveryConfirmation(.discardStage(id))))
    try await waitForPreview { !model.libraryBusy }
    #expect(!fm.fileExists(atPath: stage.path))
    #expect(fm.fileExists(atPath: pending.path))
    model.confirmRecovery(try #require(model.recoveryConfirmation(.discardPendingSelection)))
    try await waitForPreview { !model.libraryBusy }
    #expect(!fm.fileExists(atPath: pending.path))
    #expect(try Data(contentsOf: unknown) == Data([9]))
    #expect(model.libraryInventory?.canInstall == false)
}

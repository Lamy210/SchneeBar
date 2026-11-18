import AppKit
import Foundation
import SchneeBarCompanionAssets
import SchneeBarCompanionCore
@testable import SchneeBarCompanionFeature
import Testing

private enum AcquisitionFixtureError: Error { case timeout, failed }

private final class AcquisitionProbe: @unchecked Sendable {
    private let lock = NSLock()
    private let gate = DispatchSemaphore(value: 0)
    private let blockedID: UUID
    private let failedID: UUID
    private let catalogue: CompanionAssetCatalog
    private var ids: [UUID] = []
    private var active = 0
    private var peak = 0

    init(blockedID: UUID, failedID: UUID, catalogue: CompanionAssetCatalog) {
        self.blockedID = blockedID
        self.failedID = failedID
        self.catalogue = catalogue
    }

    func load(_ id: UUID) throws -> CompanionAssetCatalog {
        lock.lock()
        ids.append(id)
        active += 1
        peak = max(peak, active)
        lock.unlock()
        defer {
            lock.lock()
            active -= 1
            lock.unlock()
        }
        if id == blockedID, gate.wait(timeout: .now() + 5) != .success {
            throw AcquisitionFixtureError.timeout
        }
        if id == failedID { throw AcquisitionFixtureError.failed }
        return catalogue
    }

    func release() { gate.signal() }
    func started() -> [UUID] {
        lock.lock()
        defer { lock.unlock() }
        return ids
    }
    func peakWorkers() -> Int {
        lock.lock()
        defer { lock.unlock() }
        return peak
    }
}

@MainActor
private func waitForAcquisition(_ condition: @MainActor () -> Bool) async throws {
    let deadline = ContinuousClock.now.advanced(by: .seconds(3))
    while !condition() {
        guard ContinuousClock.now < deadline else { throw AcquisitionFixtureError.timeout }
        try await Task.sleep(for: .milliseconds(10))
    }
}

private func acquisitionCatalogue() throws -> CompanionAssetCatalog {
    let bytes = try #require(Data(base64Encoded: "R0lGODlhBAACAIEAAECA/wAAAAAAAAAAACH/C05FVFNDQVBFMi4wAwEAAAAh+QQACgAAACwAAAAABAACAAAIBwABCBwoMCAAIfkEARQAAQAsAAAAAAQAAgCB/0AAAAAAAAAAAAAACAcAAQgcKDAgADs="))
    let clip = try CompanionImageDecoder.decode(bytes)
    return try CompanionAssetCatalog(assets: [.run: clip], defaultState: .run)
}

@Test @MainActor func ownedAssetAcquisitionRevokesAndBoundsNonCooperativeWorker() async throws {
    let name = "SchneeBarTests.assetAcquisition.\(UUID())"
    let defaults = try #require(UserDefaults(suiteName: name))
    defer { defaults.removePersistentDomain(forName: name) }
    let store = CompanionHostPreferenceStore(defaults: defaults)
    try store.save(.init(enabled: true, freeze: true))
    let runtime = CompanionRuntimeCoordinator(renderer: CompanionMenuBarRenderer(onFrame: { _ in }, onClear: {}))
    let bridge = CompanionHostRuntimeBridge(store: store, runtime: runtime)
    let first = UUID(), second = UUID(), last = UUID()
    let probe = AcquisitionProbe(blockedID: first, failedID: UUID(), catalogue: try acquisitionCatalogue())
    defer { probe.release() }
    let loader = CompanionOwnedAssetAcquisition(bridge: bridge, load: { try probe.load($0) })
    defer { loader.stop() }
    #expect(!loader.request(first))
    #expect(probe.started().isEmpty)
    loader.updateEnvironment(.init(releaseApproved: true, ownsMenuSurface: true))
    #expect(loader.request(first))
    try await waitForAcquisition { probe.started() == [first] }
    #expect(loader.request(second))
    loader.updateEnvironment(.init(releaseApproved: true, awake: false, ownsMenuSurface: true))
    #expect(loader.status == .idle && loader.isBusy)
    #expect(runtime.displayedFrameIndex == nil)
    loader.updateEnvironment(.init(releaseApproved: true, ownsMenuSurface: true))
    #expect(loader.request(last))
    #expect(probe.started() == [first])
    probe.release()
    try await waitForAcquisition { !loader.isBusy }
    #expect(probe.started() == [first, last])
    #expect(probe.peakWorkers() == 1)
    #expect(loader.status == .loaded(last) && loader.decision.rendersCharacter)
    loader.stop()
    #expect(loader.status == .idle && runtime.displayedFrameIndex == nil)
}

@Test @MainActor func ownedAssetAcquisitionFailureAndCommittedDisable() async throws {
    let name = "SchneeBarTests.assetAcquisition.\(UUID())"
    let defaults = try #require(UserDefaults(suiteName: name))
    defer { defaults.removePersistentDomain(forName: name) }
    let store = CompanionHostPreferenceStore(defaults: defaults)
    try store.save(.init(enabled: true, freeze: true))
    let runtime = CompanionRuntimeCoordinator(renderer: CompanionMenuBarRenderer(onFrame: { _ in }, onClear: {}))
    let bridge = CompanionHostRuntimeBridge(store: store, runtime: runtime)
    let good = UUID(), bad = UUID()
    let probe = AcquisitionProbe(blockedID: UUID(), failedID: bad, catalogue: try acquisitionCatalogue())
    let loader = CompanionOwnedAssetAcquisition(bridge: bridge, load: { try probe.load($0) })
    defer { loader.stop() }
    loader.updateEnvironment(.init(releaseApproved: true, ownsMenuSurface: true))
    #expect(loader.request(good))
    try await waitForAcquisition { !loader.isBusy }
    #expect(loader.status == .loaded(good))
    loader.cancel()
    #expect(loader.decision.rendersCharacter)
    #expect(loader.request(bad))
    try await waitForAcquisition { !loader.isBusy }
    #expect(loader.status == .failed(bad))
    #expect(loader.decision.availability == .awaitingCatalogue)
    #expect(runtime.displayedFrameIndex == nil)
    #expect(loader.request(good))
    try await waitForAcquisition { !loader.isBusy }
    #expect(loader.decision.rendersCharacter)
    try store.save(.init())
    loader.refreshPreferences()
    #expect(loader.status == .idle && loader.decision.availability == .disabled)
    #expect(runtime.displayedFrameIndex == nil && !loader.request(good))
}


@Test @MainActor func ownedAssetRestoreSharesQueueAndRejectsRevokedCompletion() async throws {
    let name = "SchneeBarTests.assetRestore.\(UUID())"
    let defaults = try #require(UserDefaults(suiteName: name))
    defer { defaults.removePersistentDomain(forName: name) }
    let store = CompanionHostPreferenceStore(defaults: defaults)
    try store.save(.init(enabled: true, freeze: true))
    let runtime = CompanionRuntimeCoordinator(renderer: CompanionMenuBarRenderer(onFrame: { _ in }, onClear: {}))
    let bridge = CompanionHostRuntimeBridge(store: store, runtime: runtime)
    let saved = UUID(), latest = UUID()
    let probe = AcquisitionProbe(blockedID: saved, failedID: UUID(), catalogue: try acquisitionCatalogue())
    defer { probe.release() }
    let loader = CompanionOwnedAssetAcquisition(bridge: bridge, load: { try probe.load($0) },
        readSelection: { .installed(id: saved, catalogue: try probe.load(saved)) })
    defer { loader.stop() }
    #expect(!loader.restoreSavedSelection())
    loader.updateEnvironment(.init(releaseApproved: true, ownsMenuSurface: true))
    #expect(loader.restoreSavedSelection())
    try await waitForAcquisition { probe.started() == [saved] }
    #expect(loader.status == .restoring)
    loader.updateEnvironment(.init(releaseApproved: true, awake: false, ownsMenuSurface: true))
    #expect(loader.status == .idle && loader.isBusy)
    loader.updateEnvironment(.init(releaseApproved: true, ownsMenuSurface: true))
    #expect(loader.request(latest))
    #expect(probe.started() == [saved])
    probe.release()
    try await waitForAcquisition { !loader.isBusy }
    #expect(probe.started() == [saved, latest] && probe.peakWorkers() == 1)
    #expect(loader.status == .loaded(latest) && loader.decision.rendersCharacter)
}


@Test @MainActor func ownedAssetSelectionCommitCannotOverlapReadsOrOtherWrites() async throws {
    let name = "SchneeBarTests.assetCommit.\(UUID())"
    let defaults = try #require(UserDefaults(suiteName: name))
    defer { defaults.removePersistentDomain(forName: name) }
    let store = CompanionHostPreferenceStore(defaults: defaults)
    try store.save(.init(enabled: true, freeze: true))
    let runtime = CompanionRuntimeCoordinator(renderer: CompanionMenuBarRenderer(onFrame: { _ in }, onClear: {}))
    let bridge = CompanionHostRuntimeBridge(store: store, runtime: runtime)
    let writing = UUID(), reading = UUID()
    let probe = AcquisitionProbe(blockedID: writing, failedID: UUID(), catalogue: try acquisitionCatalogue())
    defer { probe.release() }
    let loader = CompanionOwnedAssetAcquisition(bridge: bridge, load: { try probe.load($0) },
        readSelection: { .installed(id: writing, catalogue: try probe.load(reading)) },
        saveSelection: { .installed(id: $0, catalogue: try probe.load($0)) },
        clearSelection: { _ = try probe.load(reading) })
    defer { loader.stop() }
    #expect(!loader.saveInstalledSelection(writing))
    loader.updateEnvironment(.init(releaseApproved: true, ownsMenuSurface: true))
    #expect(loader.saveInstalledSelection(writing))
    try await waitForAcquisition { probe.started() == [writing] }
    #expect(loader.status == .savingSelection(writing))
    #expect(!loader.request(reading) && !loader.restoreSavedSelection())
    #expect(!loader.clearSavedSelection() && !loader.saveInstalledSelection(reading))
    loader.updateEnvironment(.init(releaseApproved: true, awake: false, ownsMenuSurface: true))
    #expect(loader.status == .idle && loader.isBusy)
    loader.updateEnvironment(.init(releaseApproved: true, ownsMenuSurface: true))
    #expect(!loader.restoreSavedSelection() && !loader.request(reading))
    probe.release()
    try await waitForAcquisition { !loader.isBusy }
    #expect(loader.status == .idle && !loader.decision.rendersCharacter)
    #expect(loader.restoreSavedSelection())
    #expect(!loader.saveInstalledSelection(reading))
    try await waitForAcquisition { !loader.isBusy }
    #expect(loader.status == .loaded(writing))
    #expect(probe.started() == [writing, reading] && probe.peakWorkers() == 1)
}


@Test @MainActor func hostAssetEditorRejectsDraftAndStaleClearConfirmation() async throws {
    let name = "SchneeBarTests.assetEditor.\(UUID())"
    let defaults = try #require(UserDefaults(suiteName: name))
    defer { defaults.removePersistentDomain(forName: name) }
    let store = CompanionHostPreferenceStore(defaults: defaults)
    let id = UUID(), clearID = UUID()
    let probe = AcquisitionProbe(blockedID: UUID(), failedID: UUID(), catalogue: try acquisitionCatalogue())
    let button = NSButton()
    button.image = NSImage(size: NSSize(width: 12, height: 12))
    let owner = CompanionHostComposition(button: button, store: store,
        load: { try probe.load($0) },
        saveSelection: { .installed(id: $0, catalogue: try probe.load($0)) },
        clearSelection: { _ = try probe.load(clearID) },
        makeCPU: { runtime in CompanionSharedCPURefresh(runtime: runtime, read: { throw CancellationError() }) })
    defer { owner.stop() }
    let editor = owner.assetSettings
    owner.updateEnvironment(.init(releaseApproved: true, ownsMenuSurface: true))
    editor.packIDText = id.uuidString
    owner.settings.draft.enabled = true
    #expect(!editor.canSelect && probe.started().isEmpty)
    editor.saveCandidate()
    #expect(editor.notice == .rejected && probe.started().isEmpty)
    owner.settings.save()
    #expect(editor.canSelect)
    editor.packIDText = "not a UUID"
    #expect(!editor.canSelect)
    editor.packIDText = id.uuidString
    #expect(probe.started().isEmpty)
    editor.saveCandidate()
    #expect(editor.isBusy && !editor.canOperate)
    try await waitForAcquisition { !editor.isBusy }
    #expect(editor.status == .selectionSaved(id) && editor.canOperate)
    editor.requestClear()
    let stale = try #require(editor.clearConfirmation)
    owner.updateEnvironment(.init(releaseApproved: true, awake: false, ownsMenuSurface: true))
    #expect(editor.clearConfirmation == nil && !editor.canOperate)
    owner.updateEnvironment(.init(releaseApproved: true, ownsMenuSurface: true))
    editor.confirmClear(stale)
    #expect(probe.started() == [id])
    editor.requestClear()
    let token = try #require(editor.clearConfirmation)
    editor.confirmClear(token)
    editor.confirmClear(token)
    try await waitForAcquisition { !editor.isBusy }
    #expect(editor.status == .selectionCleared && probe.started() == [id, clearID])
}

@Test @MainActor func hostAssetEditorObservesCancelledWorkerDrainWithoutPolling() async throws {
    let name = "SchneeBarTests.assetEditorDrain.\(UUID())"
    let defaults = try #require(UserDefaults(suiteName: name))
    defer { defaults.removePersistentDomain(forName: name) }
    let store = CompanionHostPreferenceStore(defaults: defaults)
    try store.save(.init(enabled: true, freeze: true))
    let id = UUID()
    let probe = AcquisitionProbe(blockedID: id, failedID: UUID(), catalogue: try acquisitionCatalogue())
    defer { probe.release() }
    let button = NSButton()
    button.image = NSImage(size: NSSize(width: 12, height: 12))
    let owner = CompanionHostComposition(button: button, store: store,
        load: { try probe.load($0) },
        saveSelection: { .installed(id: $0, catalogue: try probe.load($0)) },
        makeCPU: { runtime in CompanionSharedCPURefresh(runtime: runtime, read: { throw CancellationError() }) })
    defer { owner.stop() }
    let editor = owner.assetSettings
    owner.updateEnvironment(.init(releaseApproved: true, ownsMenuSurface: true))
    editor.packIDText = id.uuidString
    editor.saveCandidate()
    try await waitForAcquisition { probe.started() == [id] }
    owner.updateEnvironment(.init(releaseApproved: true, awake: false, ownsMenuSurface: true))
    #expect(editor.isBusy && editor.status == .idle && !editor.canOperate)
    owner.updateEnvironment(.init(releaseApproved: true, ownsMenuSurface: true))
    #expect(editor.isBusy && !editor.canOperate)
    probe.release()
    try await waitForAcquisition { !editor.isBusy }
    #expect(editor.canOperate && editor.status == .idle)
    #expect(!owner.decision.rendersCharacter && probe.peakWorkers() == 1)
    owner.stop()
    #expect(!editor.canOperate)
}


@Test @MainActor func hostInventoryReadSharesSlotAndDiscardsRevokedSnapshot() async throws {
    let name = "SchneeBarTests.inventoryDrain.\(UUID())"
    let defaults = try #require(UserDefaults(suiteName: name))
    defer { defaults.removePersistentDomain(forName: name) }
    let store = CompanionHostPreferenceStore(defaults: defaults)
    try store.save(.init(enabled: true, freeze: true))
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false,
        attributes: [.posixPermissions: NSNumber(value: 0o700)])
    defer { try? FileManager.default.removeItem(at: root) }
    let blocked = UUID()
    let probe = AcquisitionProbe(blockedID: blocked, failedID: UUID(), catalogue: try acquisitionCatalogue())
    defer { probe.release() }
    let button = NSButton()
    button.image = NSImage(size: NSSize(width: 12, height: 12))
    let owner = CompanionHostComposition(button: button, store: store,
        load: { try probe.load($0) },
        saveSelection: { .installed(id: $0, catalogue: try probe.load($0)) },
        readInventory: {
            _ = try probe.load(blocked)
            return try CompanionOwnedPackStore.inventory(in: root)
        },
        makeCPU: { runtime in CompanionSharedCPURefresh(runtime: runtime, read: { throw CancellationError() }) })
    defer { owner.stop() }
    let editor = owner.assetSettings
    owner.updateEnvironment(.init(releaseApproved: true, ownsMenuSurface: true))
    editor.refreshInventory()
    try await waitForAcquisition { probe.started() == [blocked] }
    #expect(editor.isBusy && editor.inventoryStatus == .loading)
    #expect(!owner.requestInstalledAsset(UUID()) && !owner.saveInstalledAssetSelection(UUID()))
    owner.updateEnvironment(.init(releaseApproved: true, awake: false, ownsMenuSurface: true))
    owner.updateEnvironment(.init(releaseApproved: true, ownsMenuSurface: true))
    #expect(!owner.refreshAssetInventory() && editor.isBusy && editor.entries.isEmpty)
    probe.release()
    try await waitForAcquisition { !editor.isBusy }
    #expect(editor.inventoryStatus == .idle && editor.entries.isEmpty)
    #expect(editor.canOperate && probe.peakWorkers() == 1)
}


@Test @MainActor func hostAutomaticRestoreIsOptInAndOncePerAdmittedSession() async throws {
    let name = "SchneeBarTests.autoRestore.\(UUID())"
    let defaults = try #require(UserDefaults(suiteName: name))
    defer { defaults.removePersistentDomain(forName: name) }
    let store = CompanionHostPreferenceStore(defaults: defaults)
    try store.save(.init(enabled: true, freeze: true))
    let saved = UUID(), manual = UUID()
    let probe = AcquisitionProbe(blockedID: UUID(), failedID: UUID(), catalogue: try acquisitionCatalogue())
    let button = NSButton()
    button.image = NSImage(size: NSSize(width: 12, height: 12))
    let owner = CompanionHostComposition(button: button, store: store,
        load: { try probe.load($0) },
        readSelection: { _ = try probe.load(saved); return .builtIn },
        makeCPU: { runtime in CompanionSharedCPURefresh(runtime: runtime, read: { throw CancellationError() }) })
    defer { owner.stop() }
    owner.updateEnvironment(.init(releaseApproved: true, ownsMenuSurface: true))
    #expect(!owner.automaticAssetRestoreEnabled && probe.started().isEmpty)
    owner.enableAutomaticAssetRestore()
    try await waitForAcquisition { !owner.isAssetWorkerBusy }
    #expect(owner.assetStatus == .noSavedSelection && probe.started() == [saved])
    owner.refreshPreferences()
    owner.enableAutomaticAssetRestore()
    #expect(!owner.isAssetWorkerBusy && probe.started() == [saved])
    #expect(owner.requestInstalledAsset(manual))
    try await waitForAcquisition { !owner.isAssetWorkerBusy }
    #expect(owner.assetStatus == .loaded(manual))
    owner.refreshPreferences()
    #expect(probe.started() == [saved, manual])
    owner.updateEnvironment(.init(releaseApproved: true, awake: false, ownsMenuSurface: true))
    owner.updateEnvironment(.init(releaseApproved: true, ownsMenuSurface: true))
    try await waitForAcquisition { !owner.isAssetWorkerBusy }
    #expect(owner.assetStatus == .noSavedSelection && probe.started() == [saved, manual, saved])
    owner.disableAutomaticAssetRestore()
    owner.updateEnvironment(.init(releaseApproved: true, awake: false, ownsMenuSurface: true))
    owner.updateEnvironment(.init(releaseApproved: true, ownsMenuSurface: true))
    #expect(!owner.isAssetWorkerBusy && probe.started() == [saved, manual, saved])
}

@Test @MainActor func hostAutomaticRestoreWaitsForRevokedWorkerAndHonorsExplicitCancel() async throws {
    let name = "SchneeBarTests.autoRestoreDrain.\(UUID())"
    let defaults = try #require(UserDefaults(suiteName: name))
    defer { defaults.removePersistentDomain(forName: name) }
    let store = CompanionHostPreferenceStore(defaults: defaults)
    try store.save(.init(enabled: true, freeze: true))
    let saved = UUID(), prior = UUID()
    let probe = AcquisitionProbe(blockedID: prior, failedID: UUID(), catalogue: try acquisitionCatalogue())
    defer { probe.release() }
    let button = NSButton()
    button.image = NSImage(size: NSSize(width: 12, height: 12))
    let owner = CompanionHostComposition(button: button, store: store,
        load: { try probe.load($0) },
        readSelection: { .installed(id: saved, catalogue: try probe.load(saved)) },
        makeCPU: { runtime in CompanionSharedCPURefresh(runtime: runtime, read: { throw CancellationError() }) })
    defer { owner.stop() }
    owner.updateEnvironment(.init(releaseApproved: true, ownsMenuSurface: true))
    #expect(owner.requestInstalledAsset(prior))
    try await waitForAcquisition { probe.started() == [prior] }
    owner.enableAutomaticAssetRestore()
    owner.updateEnvironment(.init(releaseApproved: true, awake: false, ownsMenuSurface: true))
    owner.updateEnvironment(.init(releaseApproved: true, ownsMenuSurface: true))
    #expect(owner.isAssetWorkerBusy && probe.started() == [prior])
    probe.release()
    try await waitForAcquisition { owner.assetStatus == .loaded(saved) && !owner.isAssetWorkerBusy }
    #expect(probe.started() == [prior, saved] && probe.peakWorkers() == 1)
    owner.updateEnvironment(.init(releaseApproved: true, awake: false, ownsMenuSurface: true))
    owner.disableAutomaticAssetRestore()
    owner.updateEnvironment(.init(releaseApproved: true, ownsMenuSurface: true))
    owner.cancelAssetRequest()
    owner.enableAutomaticAssetRestore()
    #expect(!owner.isAssetWorkerBusy && probe.started() == [prior, saved])
}


@Test @MainActor func hostStaticPreviewDoesNotReplaceRunningCharacterAndRejectsStaleCandidate() async throws {
    let name = "SchneeBarTests.staticPreview.\(UUID())"
    let defaults = try #require(UserDefaults(suiteName: name))
    defer { defaults.removePersistentDomain(forName: name) }
    let store = CompanionHostPreferenceStore(defaults: defaults)
    try store.save(.init(enabled: true, freeze: true, allowLocalEvents: true))
    let admitted = UUID(), selected = UUID(), bad = UUID()
    let probe = AcquisitionProbe(blockedID: UUID(), failedID: bad, catalogue: try acquisitionCatalogue())
    let button = NSButton()
    button.image = NSImage(size: NSSize(width: 12, height: 12))
    let owner = CompanionHostComposition(button: button, store: store,
        load: { try probe.load($0) },
        makeCPU: { runtime in CompanionSharedCPURefresh(runtime: runtime, read: { throw CancellationError() }) })
    defer { owner.stop() }
    let editor = owner.assetSettings
    owner.updateEnvironment(.init(releaseApproved: true, ownsMenuSurface: true))
    #expect(owner.requestInstalledAsset(admitted))
    try await waitForAcquisition { !editor.isBusy }
    let session = try #require(owner.demand.localEventSession)
    let image = try #require(button.image)
    editor.packIDText = selected.uuidString
    editor.previewSelectedPack()
    #expect(editor.candidatePreviewStatus == .loading(selected) && editor.isBusy)
    try await waitForAcquisition { !editor.isBusy }
    let thumbnail = try #require(editor.candidateThumbnail)
    #expect(thumbnail.image.width == 4 && thumbnail.image.height == 2)
    #expect(editor.candidatePreviewStatus == .loaded(selected))
    #expect(owner.assetStatus == .loaded(admitted) && owner.demand.localEventSession == session)
    #expect(button.image === image)
    editor.packIDText = bad.uuidString
    #expect(editor.candidateThumbnail == nil && editor.candidatePreviewStatus == .idle)
    editor.packIDText = selected.uuidString
    #expect(editor.candidateThumbnail == nil)
    editor.packIDText = bad.uuidString
    editor.previewSelectedPack()
    try await waitForAcquisition { !editor.isBusy }
    #expect(editor.candidatePreviewStatus == .failed(bad) && editor.candidateThumbnail == nil)
    #expect(owner.assetStatus == .loaded(admitted) && owner.demand.localEventSession == session)
    #expect(button.image === image)
    owner.updateEnvironment(.init(releaseApproved: true, awake: false, ownsMenuSurface: true))
    #expect(owner.assetThumbnail == nil && editor.candidatePreviewStatus == .idle)
    #expect(probe.peakWorkers() == 1)
}

@Test @MainActor func hostStaticPreviewRevokesBlockedWorkerWithoutPublishingOldImage() async throws {
    let name = "SchneeBarTests.previewDrain.\(UUID())"
    let defaults = try #require(UserDefaults(suiteName: name))
    defer { defaults.removePersistentDomain(forName: name) }
    let store = CompanionHostPreferenceStore(defaults: defaults)
    try store.save(.init(enabled: true, freeze: true))
    let blocked = UUID(), next = UUID()
    let probe = AcquisitionProbe(blockedID: blocked, failedID: UUID(), catalogue: try acquisitionCatalogue())
    defer { probe.release() }
    let button = NSButton()
    button.image = NSImage(size: NSSize(width: 12, height: 12))
    let owner = CompanionHostComposition(button: button, store: store,
        load: { try probe.load($0) },
        makeCPU: { runtime in CompanionSharedCPURefresh(runtime: runtime, read: { throw CancellationError() }) })
    defer { owner.stop() }
    let editor = owner.assetSettings
    owner.updateEnvironment(.init(releaseApproved: true, ownsMenuSurface: true))
    editor.packIDText = blocked.uuidString
    editor.previewSelectedPack()
    try await waitForAcquisition { probe.started() == [blocked] }
    #expect(!owner.requestInstalledAsset(next) && !owner.requestAssetPreview(next))
    owner.updateEnvironment(.init(releaseApproved: true, awake: false, ownsMenuSurface: true))
    owner.updateEnvironment(.init(releaseApproved: true, ownsMenuSurface: true))
    #expect(editor.isBusy && owner.assetThumbnail == nil && editor.candidatePreviewStatus == .idle)
    #expect(!owner.requestAssetPreview(next))
    probe.release()
    try await waitForAcquisition { !editor.isBusy }
    #expect(owner.assetThumbnail == nil && owner.assetStatus == .idle)
    editor.packIDText = next.uuidString
    editor.previewSelectedPack()
    try await waitForAcquisition { !editor.isBusy }
    #expect(editor.candidatePreviewStatus == .loaded(next) && editor.candidateThumbnail != nil)
    #expect(!owner.decision.rendersCharacter && probe.peakWorkers() == 1)
}

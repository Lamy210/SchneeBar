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

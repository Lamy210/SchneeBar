import AppKit
import Foundation
import SchneeBarCompanionAssets
import SchneeBarCompanionCore
import SchneeBarCompanionEvents
@testable import SchneeBarCompanionFeature
import Testing

private enum HostCompositionFixtureError: Error { case timeout }

@MainActor
private func waitForHostComposition(_ condition: @MainActor () -> Bool) async throws {
    let deadline = ContinuousClock.now.advanced(by: .seconds(3))
    while !condition() {
        guard ContinuousClock.now < deadline else { throw HostCompositionFixtureError.timeout }
        try await Task.sleep(for: .milliseconds(10))
    }
}

private func hostCompositionCatalogue() throws -> CompanionAssetCatalog {
    let bytes = try #require(Data(base64Encoded: "R0lGODlhBAACAIEAAECA/wAAAAAAAAAAACH/C05FVFNDQVBFMi4wAwEAAAAh+QQACgAAACwAAAAABAACAAAIBwABCBwoMCAAIfkEARQAAQAsAAAAAAQAAgCB/0AAAAAAAAAAAAAACAcAAQgcKDAgADs="))
    let clip = try CompanionImageDecoder.decode(bytes)
    return try CompanionAssetCatalog(assets: [.run: clip], defaultState: .run)
}

@Test @MainActor func hostCompositionRoutesCommittedSettingsAndRevokesDemandOnSleep() async throws {
    let name = "SchneeBarTests.hostComposition.\(UUID())"
    let defaults = try #require(UserDefaults(suiteName: name))
    defer { defaults.removePersistentDomain(forName: name) }
    let store = CompanionHostPreferenceStore(defaults: defaults)
    let catalogue = try hostCompositionCatalogue()
    let button = NSButton()
    button.title = "CPU 42%"
    button.image = NSImage(size: NSSize(width: 12, height: 12))
    let original = try #require(button.image)
    var demands: [CompanionHostComposition.Demand] = []
    var reads = 0
    let owner = CompanionHostComposition(button: button, store: store,
        load: { _ in catalogue },
        makeCPU: { runtime in
            CompanionSharedCPURefresh(runtime: runtime, read: {
                reads += 1
                return .init(id: UUID(), epoch: UUID(), capturedAt: .now, percentage: 100)
            })
        },
        onDemandChanged: { demands.append($0) })
    defer { owner.stop() }
    let id = UUID()
    owner.updateEnvironment(.init(releaseApproved: true, ownsMenuSurface: true))
    owner.settings.draft.enabled = true
    owner.settings.draft.allowLocalEvents = true
    #expect(!owner.requestInstalledAsset(id))
    owner.settings.save()
    #expect(owner.requestInstalledAsset(id))
    try await waitForHostComposition { !owner.isAssetWorkerBusy }
    #expect(owner.assetStatus == .loaded(id))
    #expect(owner.demand.cpu && owner.demand.localEventSession != nil)
    let firstSession = owner.demand.localEventSession
    #expect(button.image !== original && button.title == "CPU 42%")
    await owner.refreshCPU(isCurrent: { true })
    #expect(reads == 1)
    owner.settings.draft.freeze = true
    #expect(owner.demand.cpu)
    owner.settings.save()
    #expect(!owner.demand.cpu && owner.demand.localEventSession == firstSession)
    await owner.refreshCPU(isCurrent: { true })
    #expect(reads == 1)
    owner.updateEnvironment(.init(releaseApproved: true, awake: false, ownsMenuSurface: true))
    #expect(button.image === original && owner.demand.localEventSession == nil)
    #expect(owner.decision.availability == .asleep && !owner.isStopped)
    owner.updateEnvironment(.init(releaseApproved: true, ownsMenuSurface: true))
    #expect(owner.requestInstalledAsset(id))
    try await waitForHostComposition { !owner.isAssetWorkerBusy }
    #expect(owner.demand.localEventSession != nil && owner.demand.localEventSession != firstSession)
    owner.stop()
    #expect(owner.isStopped && button.image === original)
    #expect(demands.last?.cpu == false && demands.last?.localEventSession == nil)
    owner.updateEnvironment(.init(releaseApproved: true, ownsMenuSurface: true))
    #expect(!owner.requestInstalledAsset(id))
}

@Test @MainActor func hostCompositionExternalImageReplacementStopsWithoutClobbering() async throws {
    let name = "SchneeBarTests.hostComposition.\(UUID())"
    let defaults = try #require(UserDefaults(suiteName: name))
    defer { defaults.removePersistentDomain(forName: name) }
    let store = CompanionHostPreferenceStore(defaults: defaults)
    try store.save(.init(enabled: true, freeze: true, allowLocalEvents: true))
    let catalogue = try hostCompositionCatalogue()
    let button = NSButton()
    button.image = NSImage(size: NSSize(width: 12, height: 12))
    let owner = CompanionHostComposition(button: button, store: store,
        load: { _ in catalogue },
        makeCPU: { runtime in
            CompanionSharedCPURefresh(runtime: runtime, read: {
                Issue.record("Frozen owner must not acquire CPU")
                return .init(id: UUID(), epoch: UUID(), capturedAt: .now, percentage: 100)
            })
        })
    defer { owner.stop() }
    owner.updateEnvironment(.init(releaseApproved: true, ownsMenuSurface: true))
    #expect(owner.requestInstalledAsset(UUID()))
    try await waitForHostComposition { !owner.isAssetWorkerBusy }
    #expect(owner.demand.localEventSession != nil)
    let external = NSImage(size: NSSize(width: 16, height: 16))
    button.image = external
    await owner.refreshCPU(isCurrent: { true })
    #expect(owner.isStopped && owner.demand.localEventSession == nil)
    #expect(button.image === external)
    #expect(owner.decision.availability == .releaseBlocked)
    #expect(!owner.requestInstalledAsset(UUID()))
}


@Test @MainActor func hostCompositionLocalEventsRequireCommittedOptInAndCurrentSession() async throws {
    let name = "SchneeBarTests.hostEvent.\(UUID())"
    let defaults = try #require(UserDefaults(suiteName: name))
    defer { defaults.removePersistentDomain(forName: name) }
    let store = CompanionHostPreferenceStore(defaults: defaults)
    try store.save(.init(enabled: true, freeze: true))
    let catalogue = try hostCompositionCatalogue()
    let button = NSButton()
    button.image = NSImage(size: NSSize(width: 12, height: 12))
    let owner = CompanionHostComposition(button: button, store: store,
        load: { _ in catalogue },
        makeCPU: { runtime in
            CompanionSharedCPURefresh(runtime: runtime, read: { throw CancellationError() })
        })
    defer { owner.stop() }
    let id = UUID()
    owner.updateEnvironment(.init(releaseApproved: true, ownsMenuSurface: true))
    #expect(owner.requestInstalledAsset(id))
    try await waitForHostComposition { !owner.isAssetWorkerBusy }
    var evaluations = 0
    func payload() -> CompanionLocalEventIngress.Payload {
        evaluations += 1
        return .bytes(Data(#"{"phase":"started"}"#.utf8))
    }
    owner.settings.draft.allowLocalEvents = true
    #expect(owner.demand.localEventSession == nil)
    #expect(owner.receiveLocalEvent(session: UUID(), kind: .build, payload: payload) == nil)
    #expect(evaluations == 0)
    owner.settings.save()
    let first = try #require(owner.demand.localEventSession)
    #expect(owner.receiveLocalEvent(session: first, kind: .build, payload: payload) == .accepted)
    #expect(evaluations == 1)
    #expect(owner.receiveLocalEvent(session: first, kind: .build) { .oversized } == .oversized)
    owner.updateEnvironment(.init(releaseApproved: true, awake: false, ownsMenuSurface: true))
    #expect(owner.receiveLocalEvent(session: first, kind: .build, payload: payload) == nil)
    owner.updateEnvironment(.init(releaseApproved: true, ownsMenuSurface: true))
    #expect(owner.requestInstalledAsset(id))
    try await waitForHostComposition { !owner.isAssetWorkerBusy }
    let second = try #require(owner.demand.localEventSession)
    #expect(second != first)
    #expect(owner.receiveLocalEvent(session: first, kind: .build, payload: payload) == nil)
    #expect(evaluations == 1)
    #expect(owner.receiveLocalEvent(session: second, kind: .build, payload: payload) == .accepted)
    owner.settings.draft.allowLocalEvents = false
    owner.settings.save()
    #expect(owner.receiveLocalEvent(session: second, kind: .build, payload: payload) == nil)
    #expect(evaluations == 2)
}

@Test @MainActor func hostCompositionEventChecksImageOwnershipBeforeParsing() async throws {
    let name = "SchneeBarTests.hostEvent.\(UUID())"
    let defaults = try #require(UserDefaults(suiteName: name))
    defer { defaults.removePersistentDomain(forName: name) }
    let store = CompanionHostPreferenceStore(defaults: defaults)
    try store.save(.init(enabled: true, freeze: true, allowLocalEvents: true))
    let catalogue = try hostCompositionCatalogue()
    let button = NSButton()
    button.image = NSImage(size: NSSize(width: 12, height: 12))
    let owner = CompanionHostComposition(button: button, store: store,
        load: { _ in catalogue },
        makeCPU: { runtime in
            CompanionSharedCPURefresh(runtime: runtime, read: { throw CancellationError() })
        })
    defer { owner.stop() }
    owner.updateEnvironment(.init(releaseApproved: true, ownsMenuSurface: true))
    #expect(owner.requestInstalledAsset(UUID()))
    try await waitForHostComposition { !owner.isAssetWorkerBusy }
    let session = try #require(owner.demand.localEventSession)
    let external = NSImage(size: NSSize(width: 16, height: 16))
    button.image = external
    #expect(owner.receiveLocalEvent(session: session, kind: .build) {
        Issue.record("Lost image owner evaluated payload")
        return .malformed
    } == nil)
    #expect(owner.isStopped && owner.demand.localEventSession == nil)
    #expect(button.image === external)
}


@Test @MainActor func hostCompositionRestoresSavedPackWithoutRepairingDisk() async throws {
    let name = "SchneeBarTests.hostRestore.\(UUID())"
    let defaults = try #require(UserDefaults(suiteName: name))
    defer { defaults.removePersistentDomain(forName: name) }
    let store = CompanionHostPreferenceStore(defaults: defaults)
    try store.save(.init(enabled: true, freeze: true, allowLocalEvents: true))
    let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let source = tmp.appendingPathComponent("fixture.schneerunner")
    let root = tmp.appendingPathComponent("owned")
    try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tmp) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false,
        attributes: [.posixPermissions: NSNumber(value: 0o700)])
    let gif = try #require(Data(base64Encoded: "R0lGODlhBAACAIEAAECA/wAAAAAAAAAAACH/C05FVFNDQVBFMi4wAwEAAAAh+QQACgAAACwAAAAABAACAAAIBwABCBwoMCAAIfkEARQAAQAsAAAAAAQAAgCB/0AAAAAAAAAAAAAACAcAAQgcKDAgADs="))
    try gif.write(to: source.appendingPathComponent("run.gif"))
    try Data(#"{"formatVersion":1,"name":"Fixture","defaultState":"run","clips":[{"state":"run","kind":"gif","path":"run.gif"}]}"#.utf8)
        .write(to: source.appendingPathComponent("character.json"))
    let installed = try CompanionOwnedPackStore.install(from: source, into: root)
    _ = try CompanionOwnedPackStore.select(id: installed.id, in: root)
    let record = root.appendingPathComponent(".selection-v1")
    let savedBytes = try Data(contentsOf: record)
    let button = NSButton()
    button.image = NSImage(size: NSSize(width: 12, height: 12))
    let original = try #require(button.image)
    let owner = CompanionHostComposition(button: button, store: store,
        load: { try CompanionOwnedPackStore.load(id: $0, from: root) },
        readSelection: { try CompanionOwnedPackStore.readSelection(in: root) },
        makeCPU: { runtime in CompanionSharedCPURefresh(runtime: runtime, read: { throw CancellationError() }) })
    defer { owner.stop() }
    #expect(!owner.restoreSavedAssetSelection())
    owner.updateEnvironment(.init(releaseApproved: true, ownsMenuSurface: true))
    #expect(owner.restoreSavedAssetSelection())
    try await waitForHostComposition { !owner.isAssetWorkerBusy }
    #expect(owner.assetStatus == .loaded(installed.id))
    #expect(owner.demand.localEventSession != nil && button.image !== original)
    let package = root.appendingPathComponent(installed.id.uuidString.lowercased() + ".schneerunner")
    try Data([1, 2, 3]).write(to: package.appendingPathComponent("run.gif"))
    #expect(owner.restoreSavedAssetSelection())
    try await waitForHostComposition { !owner.isAssetWorkerBusy }
    #expect(owner.assetStatus == .savedAssetUnavailable(installed.id))
    #expect(owner.demand.localEventSession == nil && button.image === original)
    #expect(try Data(contentsOf: record) == savedBytes)
    try CompanionOwnedPackStore.selectBuiltIn(in: root)
    #expect(owner.restoreSavedAssetSelection())
    try await waitForHostComposition { !owner.isAssetWorkerBusy }
    #expect(owner.assetStatus == .noSavedSelection && button.image === original)
    #expect(!FileManager.default.fileExists(atPath: record.path))
    owner.stop()
    #expect(!owner.restoreSavedAssetSelection())
}


@Test @MainActor func hostCompositionSelectionCommitAndClearPersistOnlyExplicitActions() async throws {
    let name = "SchneeBarTests.hostCommit.\(UUID())"
    let defaults = try #require(UserDefaults(suiteName: name))
    defer { defaults.removePersistentDomain(forName: name) }
    let store = CompanionHostPreferenceStore(defaults: defaults)
    try store.save(.init(enabled: true, freeze: true, allowLocalEvents: true))
    let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let source = tmp.appendingPathComponent("fixture.schneerunner")
    let root = tmp.appendingPathComponent("owned")
    try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tmp) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false,
        attributes: [.posixPermissions: NSNumber(value: 0o700)])
    let gif = try #require(Data(base64Encoded: "R0lGODlhBAACAIEAAECA/wAAAAAAAAAAACH/C05FVFNDQVBFMi4wAwEAAAAh+QQACgAAACwAAAAABAACAAAIBwABCBwoMCAAIfkEARQAAQAsAAAAAAQAAgCB/0AAAAAAAAAAAAAACAcAAQgcKDAgADs="))
    try gif.write(to: source.appendingPathComponent("run.gif"))
    try Data(#"{"formatVersion":1,"name":"Fixture","defaultState":"run","clips":[{"state":"run","kind":"gif","path":"run.gif"}]}"#.utf8)
        .write(to: source.appendingPathComponent("character.json"))
    let installed = try CompanionOwnedPackStore.install(from: source, into: root)
    let record = root.appendingPathComponent(".selection-v1")
    let button = NSButton()
    button.image = NSImage(size: NSSize(width: 12, height: 12))
    let original = try #require(button.image)
    let owner = CompanionHostComposition(button: button, store: store,
        load: { try CompanionOwnedPackStore.load(id: $0, from: root) },
        readSelection: { try CompanionOwnedPackStore.readSelection(in: root) },
        saveSelection: { try CompanionOwnedPackStore.select(id: $0, in: root) },
        clearSelection: { try CompanionOwnedPackStore.selectBuiltIn(in: root) },
        makeCPU: { runtime in CompanionSharedCPURefresh(runtime: runtime, read: { throw CancellationError() }) })
    defer { owner.stop() }
    #expect(!owner.saveInstalledAssetSelection(installed.id))
    owner.updateEnvironment(.init(releaseApproved: true, ownsMenuSurface: true))
    #expect(owner.requestInstalledAsset(installed.id))
    try await waitForHostComposition { !owner.isAssetWorkerBusy }
    #expect(!FileManager.default.fileExists(atPath: record.path))
    #expect(owner.saveInstalledAssetSelection(installed.id))
    try await waitForHostComposition { !owner.isAssetWorkerBusy }
    #expect(owner.assetStatus == .selectionSaved(installed.id))
    let committed = try Data(contentsOf: record)
    #expect(owner.demand.localEventSession != nil)
    #expect(owner.saveInstalledAssetSelection(UUID()))
    try await waitForHostComposition { !owner.isAssetWorkerBusy }
    #expect(owner.assetStatus == .selectionCommitFailed)
    #expect(try Data(contentsOf: record) == committed)
    #expect(button.image === original && owner.demand.localEventSession == nil)
    #expect(owner.restoreSavedAssetSelection())
    try await waitForHostComposition { !owner.isAssetWorkerBusy }
    #expect(owner.assetStatus == .loaded(installed.id))
    #expect(owner.clearSavedAssetSelection())
    try await waitForHostComposition { !owner.isAssetWorkerBusy }
    #expect(owner.assetStatus == .selectionCleared && button.image === original)
    #expect(!FileManager.default.fileExists(atPath: record.path))
}


@Test @MainActor func hostAssetPickerListsMetadataWithoutReplacingAdmittedCatalogue() async throws {
    let name = "SchneeBarTests.hostPicker.\(UUID())"
    let defaults = try #require(UserDefaults(suiteName: name))
    defer { defaults.removePersistentDomain(forName: name) }
    let store = CompanionHostPreferenceStore(defaults: defaults)
    try store.save(.init(enabled: true, freeze: true, allowLocalEvents: true))
    let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let source = tmp.appendingPathComponent("fixture.schneerunner")
    let root = tmp.appendingPathComponent("owned")
    try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tmp) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false,
        attributes: [.posixPermissions: NSNumber(value: 0o700)])
    let gif = try #require(Data(base64Encoded: "R0lGODlhBAACAIEAAECA/wAAAAAAAAAAACH/C05FVFNDQVBFMi4wAwEAAAAh+QQACgAAACwAAAAABAACAAAIBwABCBwoMCAAIfkEARQAAQAsAAAAAAQAAgCB/0AAAAAAAAAAAAAACAcAAQgcKDAgADs="))
    try gif.write(to: source.appendingPathComponent("run.gif"))
    try Data(#"{"formatVersion":1,"name":"Fixture","defaultState":"run","clips":[{"state":"run","kind":"gif","path":"run.gif"}]}"#.utf8)
        .write(to: source.appendingPathComponent("character.json"))
    let good = try CompanionOwnedPackStore.install(from: source, into: root)
    let broken = try CompanionOwnedPackStore.install(from: source, into: root)
    let badManifest = try CompanionOwnedPackStore.install(from: source, into: root)
    try Data([1]).write(to: root.appendingPathComponent(broken.id.uuidString.lowercased() + ".schneerunner/run.gif"))
    try Data([2]).write(to: root.appendingPathComponent(badManifest.id.uuidString.lowercased() + ".schneerunner/character.json"))
    _ = try CompanionOwnedPackStore.select(id: good.id, in: root)
    let record = root.appendingPathComponent(".selection-v1")
    let original = try Data(contentsOf: record)
    let button = NSButton()
    button.image = NSImage(size: NSSize(width: 12, height: 12))
    let owner = CompanionHostComposition(button: button, store: store,
        load: { try CompanionOwnedPackStore.load(id: $0, from: root) },
        readSelection: { try CompanionOwnedPackStore.readSelection(in: root) },
        readInventory: { try CompanionOwnedPackStore.inventory(in: root) },
        makeCPU: { runtime in CompanionSharedCPURefresh(runtime: runtime, read: { throw CancellationError() }) })
    defer { owner.stop() }
    let editor = owner.assetSettings
    owner.updateEnvironment(.init(releaseApproved: true, ownsMenuSurface: true))
    editor.restoreSaved()
    try await waitForHostComposition { !editor.isBusy }
    let session = try #require(owner.demand.localEventSession)
    editor.refreshInventory()
    #expect(editor.isBusy && editor.inventoryStatus == .loading)
    try await waitForHostComposition { !editor.isBusy }
    #expect(editor.inventoryStatus == .loaded && editor.entries.count == 3)
    #expect(editor.entries.first(where: { $0.id == broken.id })?.name == "Fixture")
    #expect(editor.entries.first(where: { $0.id == badManifest.id })?.name == nil)
    #expect(owner.demand.localEventSession == session && owner.assetStatus == .loaded(good.id))
    editor.chooseListedPack(badManifest.id)
    #expect(editor.candidateID == nil)
    editor.chooseListedPack(good.id)
    #expect(editor.listedID == good.id && editor.canSelect)
    #expect(try Data(contentsOf: record) == original)
    owner.updateEnvironment(.init(releaseApproved: true, awake: false, ownsMenuSurface: true))
    #expect(editor.entries.isEmpty && editor.candidateID == nil && !editor.canOperate)
}


@Test @MainActor func hostPackImportCopiesWithoutSelectingAndRejectsOldPanelToken() async throws {
    let name = "SchneeBarTests.hostImport.\(UUID())"
    let defaults = try #require(UserDefaults(suiteName: name))
    defer { defaults.removePersistentDomain(forName: name) }
    let store = CompanionHostPreferenceStore(defaults: defaults)
    try store.save(.init(enabled: true, freeze: true, allowLocalEvents: true))
    let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let source = tmp.appendingPathComponent("fixture.schneerunner")
    let root = tmp.appendingPathComponent("owned")
    try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tmp) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false,
        attributes: [.posixPermissions: NSNumber(value: 0o700)])
    let gif = try #require(Data(base64Encoded: "R0lGODlhBAACAIEAAECA/wAAAAAAAAAAACH/C05FVFNDQVBFMi4wAwEAAAAh+QQACgAAACwAAAAABAACAAAIBwABCBwoMCAAIfkEARQAAQAsAAAAAAQAAgCB/0AAAAAAAAAAAAAACAcAAQgcKDAgADs="))
    try gif.write(to: source.appendingPathComponent("run.gif"))
    try Data(#"{"formatVersion":1,"name":"Fixture","defaultState":"run","clips":[{"state":"run","kind":"gif","path":"run.gif"}]}"#.utf8)
        .write(to: source.appendingPathComponent("character.json"))
    let initial = try CompanionOwnedPackStore.install(from: source, into: root)
    _ = try CompanionOwnedPackStore.select(id: initial.id, in: root)
    let record = root.appendingPathComponent(".selection-v1")
    let original = try Data(contentsOf: record)
    let button = NSButton()
    button.image = NSImage(size: NSSize(width: 12, height: 12))
    let owner = CompanionHostComposition(button: button, store: store,
        load: { try CompanionOwnedPackStore.load(id: $0, from: root) },
        readInventory: { try CompanionOwnedPackStore.inventory(in: root) },
        installPack: { try CompanionOwnedPackStore.install(from: $0, into: root).id },
        makeCPU: { runtime in CompanionSharedCPURefresh(runtime: runtime, read: { throw CancellationError() }) })
    defer { owner.stop() }
    let editor = owner.assetSettings
    owner.updateEnvironment(.init(releaseApproved: true, ownsMenuSurface: true))
    #expect(!editor.canImport)
    editor.refreshInventory()
    try await waitForHostComposition { !editor.isBusy }
    #expect(editor.canImport)
    let stale = try #require(editor.beginImportChoice())
    owner.updateEnvironment(.init(releaseApproved: true, awake: false, ownsMenuSurface: true))
    owner.updateEnvironment(.init(releaseApproved: true, ownsMenuSurface: true))
    editor.completeImportChoice(stale, url: source)
    #expect(!owner.isAssetWorkerBusy)
    #expect(try CompanionOwnedPackStore.inventory(in: root).entries.count == 1)
    #expect(owner.requestInstalledAsset(initial.id))
    try await waitForHostComposition { !editor.isBusy }
    editor.refreshInventory()
    try await waitForHostComposition { !editor.isBusy }
    let session = try #require(owner.demand.localEventSession)
    let image = try #require(button.image)
    let token = try #require(editor.beginImportChoice())
    editor.completeImportChoice(token, url: source)
    editor.completeImportChoice(token, url: source)
    #expect(editor.isBusy && editor.importStatus == .importing)
    try await waitForHostComposition { !editor.isBusy }
    guard case .installed(let id) = editor.importStatus else { Issue.record("Expected imported ID"); return }
    #expect(id != initial.id)
    #expect(owner.assetStatus == .loaded(initial.id) && owner.demand.localEventSession == session)
    #expect(button.image === image && editor.entries.isEmpty && !editor.canImport)
    #expect(try Data(contentsOf: record) == original)
    #expect(try Data(contentsOf: source.appendingPathComponent("run.gif")) == gif)
    editor.refreshInventory()
    try await waitForHostComposition { !editor.isBusy }
    #expect(editor.entries.count == 2 && editor.entries.contains(where: { $0.id == id }))
    #expect(editor.canImport)
}


@Test @MainActor func hostSingleImageImportRoutesChooserModeWithoutSelecting() async throws {
    let name = "SchneeBarTests.imageImport.\(UUID())"
    let defaults = try #require(UserDefaults(suiteName: name))
    defer { defaults.removePersistentDomain(forName: name) }
    let store = CompanionHostPreferenceStore(defaults: defaults)
    try store.save(.init(enabled: true, freeze: true))
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false,
        attributes: [.posixPermissions: NSNumber(value: 0o700)])
    defer { try? FileManager.default.removeItem(at: root) }
    let input = root.deletingLastPathComponent().appendingPathComponent(UUID().uuidString + ".png")
    let bytes = try #require(Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAQAAAACCAYAAAB/qH1jAAAAE0lEQVR4nGOUSznxnwEJMDGgAQBG3gJNNKg6iwAAAABJRU5ErkJggg=="))
    try bytes.write(to: input)
    defer { try? FileManager.default.removeItem(at: input) }
    let button = NSButton()
    button.image = NSImage(size: NSSize(width: 12, height: 12))
    let original = try #require(button.image)
    let owner = CompanionHostComposition(button: button, store: store,
        load: { try CompanionOwnedPackStore.load(id: $0, from: root) },
        readInventory: { try CompanionOwnedPackStore.inventory(in: root) },
        installPack: { try CompanionOwnedPackStore.install(from: $0, into: root).id },
        installImage: { try CompanionOwnedPackStore.installImage(from: $0, into: root).id },
        makeCPU: { runtime in CompanionSharedCPURefresh(runtime: runtime, read: { throw CancellationError() }) })
    defer { owner.stop() }
    let editor = owner.assetSettings
    owner.updateEnvironment(.init(releaseApproved: true, ownsMenuSurface: true))
    editor.refreshInventory()
    try await waitForHostComposition { !editor.isBusy }
    let stale = try #require(editor.beginImportChoice(singleImage: true))
    editor.completeImportChoice(stale, url: nil)
    let token = try #require(editor.beginImportChoice(singleImage: true))
    editor.completeImportChoice(stale, url: input)
    #expect(!editor.isBusy)
    editor.completeImportChoice(token, url: input)
    try await waitForHostComposition { !editor.isBusy }
    guard case .installed(let id) = editor.importStatus else { Issue.record("Expected installed image"); return }
    #expect(button.image === original && !owner.decision.rendersCharacter)
    #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent(".selection-v1").path))
    #expect(try Data(contentsOf: input) == bytes)
    #expect(try CompanionOwnedPackStore.load(id: id, from: root).defaultAsset.frames.count == 8)
    editor.refreshInventory()
    try await waitForHostComposition { !editor.isBusy }
    #expect(editor.entries.map(\.id) == [id])
}


@Test @MainActor func hostLibraryTrashProtectsDisplayedAndSavedPacksAndConsumesConfirmation() async throws {
    let name = "SchneeBarTests.libraryTrash.\(UUID())"
    let defaults = try #require(UserDefaults(suiteName: name))
    defer { defaults.removePersistentDomain(forName: name) }
    let store = CompanionHostPreferenceStore(defaults: defaults)
    try store.save(.init(enabled: true, freeze: true, allowLocalEvents: true))
    let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let source = tmp.appendingPathComponent("fixture.schneerunner")
    let root = tmp.appendingPathComponent("owned")
    try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tmp) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false,
        attributes: [.posixPermissions: NSNumber(value: 0o700)])
    let gif = try #require(Data(base64Encoded: "R0lGODlhBAACAIEAAECA/wAAAAAAAAAAACH/C05FVFNDQVBFMi4wAwEAAAAh+QQACgAAACwAAAAABAACAAAIBwABCBwoMCAAIfkEARQAAQAsAAAAAAQAAgCB/0AAAAAAAAAAAAAACAcAAQgcKDAgADs="))
    try gif.write(to: source.appendingPathComponent("run.gif"))
    try Data(#"{"formatVersion":1,"name":"Fixture","defaultState":"run","clips":[{"state":"run","kind":"gif","path":"run.gif"}]}"#.utf8)
        .write(to: source.appendingPathComponent("character.json"))
    let shown = try CompanionOwnedPackStore.install(from: source, into: root)
    let saved = try CompanionOwnedPackStore.install(from: source, into: root)
    let spare = try CompanionOwnedPackStore.install(from: source, into: root)
    _ = try CompanionOwnedPackStore.select(id: saved.id, in: root)
    let record = root.appendingPathComponent(".selection-v1")
    let original = try Data(contentsOf: record)
    let button = NSButton()
    button.image = NSImage(size: NSSize(width: 12, height: 12))
    let owner = CompanionHostComposition(button: button, store: store,
        load: { try CompanionOwnedPackStore.load(id: $0, from: root) },
        readInventory: { try CompanionOwnedPackStore.inventory(in: root) },
        manageLibrary: { action in
            switch action {
            case .trash(let id): try CompanionOwnedPackStore.trashUnselected(id: id, in: root)
            case .restore(let id): try CompanionOwnedPackStore.restore(id: id, in: root)
                case .purge(let id): try CompanionOwnedPackStore.purgeUnselectedTrash(id: id, in: root)
                case .discardStage(let id): try CompanionOwnedPackStore.discardAbandonedStage(id: id, in: root)
                case .discardPendingSelection: try CompanionOwnedPackStore.discardPendingSelection(in: root)
            }
        },
        makeCPU: { runtime in CompanionSharedCPURefresh(runtime: runtime, read: { throw CancellationError() }) })
    defer { owner.stop() }
    let editor = owner.assetSettings
    owner.updateEnvironment(.init(releaseApproved: true, ownsMenuSurface: true))
    #expect(owner.requestInstalledAsset(shown.id))
    try await waitForHostComposition { !editor.isBusy }
    owner.cancelAssetRequest() // Cancelling status must not forget the displayed ID.
    editor.refreshInventory()
    try await waitForHostComposition { !editor.isBusy }
    #expect(owner.displayedPackID == shown.id && owner.assetStatus == .idle)
    #expect(!owner.manageAssetLibrary(.trash(shown.id)))
    editor.chooseListedPack(saved.id)
    editor.requestTrashCandidate()
    let protectedToken = try #require(editor.libraryConfirmation).token
    editor.confirmLibraryAction(protectedToken)
    try await waitForHostComposition { !editor.isBusy }
    #expect(editor.libraryStatus == .failed(.trash(saved.id)))
    #expect(try Data(contentsOf: record) == original)
    editor.refreshInventory()
    try await waitForHostComposition { !editor.isBusy }
    let eventSession = try #require(owner.demand.localEventSession)
    let image = try #require(button.image)
    editor.chooseListedPack(spare.id)
    editor.requestTrashCandidate()
    let stale = try #require(editor.libraryConfirmation).token
    editor.chooseListedPack(saved.id)
    editor.confirmLibraryAction(stale)
    #expect(!editor.isBusy)
    editor.chooseListedPack(spare.id)
    editor.requestTrashCandidate()
    let token = try #require(editor.libraryConfirmation).token
    editor.confirmLibraryAction(token)
    editor.confirmLibraryAction(token)
    try await waitForHostComposition { !editor.isBusy }
    #expect(editor.libraryStatus == .completed(.trash(spare.id)))
    #expect(owner.displayedPackID == shown.id && owner.demand.localEventSession == eventSession)
    #expect(button.image === image && editor.entries.isEmpty)
    editor.refreshInventory()
    try await waitForHostComposition { !editor.isBusy }
    #expect(editor.trashedIDs == [spare.id])
    editor.requestRestoreTrash(spare.id)
    editor.confirmLibraryAction(try #require(editor.libraryConfirmation).token)
    try await waitForHostComposition { !editor.isBusy }
    #expect(editor.libraryStatus == .completed(.restore(spare.id)))
    #expect(try Data(contentsOf: record) == original)
    editor.refreshInventory()
    try await waitForHostComposition { !editor.isBusy }
    #expect(editor.trashedIDs.isEmpty && editor.entries.count == 3)
}


@Test @MainActor func hostLibraryRecoveryRequiresTypedConfirmationAndPreservesCommittedChoice() async throws {
    let name = "SchneeBarTests.libraryRecovery.\(UUID())"
    let defaults = try #require(UserDefaults(suiteName: name))
    defer { defaults.removePersistentDomain(forName: name) }
    let store = CompanionHostPreferenceStore(defaults: defaults)
    try store.save(.init(enabled: true, freeze: true))
    let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let source = tmp.appendingPathComponent("fixture.schneerunner")
    let root = tmp.appendingPathComponent("owned")
    let fm = FileManager.default
    try fm.createDirectory(at: source, withIntermediateDirectories: true)
    defer { try? fm.removeItem(at: tmp) }
    try fm.createDirectory(at: root, withIntermediateDirectories: false,
        attributes: [.posixPermissions: NSNumber(value: 0o700)])
    let gif = try #require(Data(base64Encoded: "R0lGODlhBAACAIEAAECA/wAAAAAAAAAAACH/C05FVFNDQVBFMi4wAwEAAAAh+QQACgAAACwAAAAABAACAAAIBwABCBwoMCAAIfkEARQAAQAsAAAAAAQAAgCB/0AAAAAAAAAAAAAACAcAAQgcKDAgADs="))
    try gif.write(to: source.appendingPathComponent("run.gif"))
    try Data(#"{"formatVersion":1,"name":"Fixture","defaultState":"run","clips":[{"state":"run","kind":"gif","path":"run.gif"}]}"#.utf8)
        .write(to: source.appendingPathComponent("character.json"))
    let saved = try CompanionOwnedPackStore.install(from: source, into: root)
    let spare = try CompanionOwnedPackStore.install(from: source, into: root)
    _ = try CompanionOwnedPackStore.select(id: saved.id, in: root)
    try CompanionOwnedPackStore.trashUnselected(id: spare.id, in: root)
    let record = root.appendingPathComponent(".selection-v1")
    let original = try Data(contentsOf: record)
    let stageID = UUID()
    let stage = root.appendingPathComponent(".stage-" + stageID.uuidString.lowercased())
    try fm.createDirectory(at: stage, withIntermediateDirectories: false,
        attributes: [.posixPermissions: NSNumber(value: 0o700)])
    let pending = root.appendingPathComponent(".selection-pending")
    try #require(fm.createFile(atPath: pending.path, contents: Data("unfinished".utf8),
        attributes: [.posixPermissions: NSNumber(value: 0o600)]))
    let unknown = root.appendingPathComponent("unknown")
    try Data([42]).write(to: unknown)
    let button = NSButton()
    button.image = NSImage(size: NSSize(width: 12, height: 12))
    let owner = CompanionHostComposition(button: button, store: store,
        load: { try CompanionOwnedPackStore.load(id: $0, from: root) },
        readInventory: { try CompanionOwnedPackStore.inventory(in: root) },
        manageLibrary: { action in
            switch action {
            case .trash(let id): try CompanionOwnedPackStore.trashUnselected(id: id, in: root)
            case .restore(let id): try CompanionOwnedPackStore.restore(id: id, in: root)
            case .purge(let id): try CompanionOwnedPackStore.purgeUnselectedTrash(id: id, in: root)
            case .discardStage(let id): try CompanionOwnedPackStore.discardAbandonedStage(id: id, in: root)
            case .discardPendingSelection: try CompanionOwnedPackStore.discardPendingSelection(in: root)
            }
        },
        makeCPU: { runtime in CompanionSharedCPURefresh(runtime: runtime, read: { throw CancellationError() }) })
    defer { owner.stop() }
    let editor = owner.assetSettings
    owner.updateEnvironment(.init(releaseApproved: true, ownsMenuSurface: true))
    editor.refreshInventory()
    try await waitForHostComposition { !editor.isBusy }
    #expect(editor.trashedIDs == [spare.id] && editor.abandonedStageIDs == [stageID])
    #expect(editor.pendingSelectionRecovery && editor.unknownEntryCount == 1)
    #expect(!editor.inventoryAllowsImport)
    editor.requestPurgeTrash(spare.id)
    let stale = try #require(editor.libraryConfirmation).token
    editor.recoveryConfirmationText = "delete"
    editor.confirmLibraryAction(stale)
    #expect(!editor.isBusy && !editor.canConfirmLibraryAction)
    editor.recoveryConfirmationText = "DELETE"
    editor.requestDiscardStage(stageID)
    #expect(editor.recoveryConfirmationText.isEmpty && !editor.canConfirmLibraryAction)
    editor.confirmLibraryAction(stale)
    #expect(!editor.isBusy)
    let stageToken = try #require(editor.libraryConfirmation).token
    editor.recoveryConfirmationText = "DELETE"
    editor.confirmLibraryAction(stageToken)
    editor.confirmLibraryAction(stageToken)
    try await waitForHostComposition { !editor.isBusy }
    #expect(editor.libraryStatus == .completed(.discardStage(stageID)))
    #expect(!fm.fileExists(atPath: stage.path))
    editor.refreshInventory()
    try await waitForHostComposition { !editor.isBusy }
    editor.requestDiscardPendingSelection()
    editor.recoveryConfirmationText = "DELETE"
    editor.confirmLibraryAction(try #require(editor.libraryConfirmation).token)
    try await waitForHostComposition { !editor.isBusy }
    #expect(editor.libraryStatus == .completed(.discardPendingSelection))
    #expect(!fm.fileExists(atPath: pending.path))
    editor.refreshInventory()
    try await waitForHostComposition { !editor.isBusy }
    editor.requestPurgeTrash(spare.id)
    editor.recoveryConfirmationText = "DELETE"
    editor.confirmLibraryAction(try #require(editor.libraryConfirmation).token)
    try await waitForHostComposition { !editor.isBusy }
    #expect(editor.libraryStatus == .completed(.purge(spare.id)))
    #expect(try Data(contentsOf: record) == original)
    #expect(try Data(contentsOf: unknown) == Data([42]))
    editor.refreshInventory()
    try await waitForHostComposition { !editor.isBusy }
    #expect(editor.entries.map(\.id) == [saved.id] && editor.trashedIDs.isEmpty)
    #expect(editor.abandonedStageIDs.isEmpty && !editor.pendingSelectionRecovery)
    #expect(editor.unknownEntryCount == 1 && !editor.inventoryAllowsImport)
}

import AppKit
import Foundation
import SchneeBarCompanionAssets
import SchneeBarCompanionCore
import SchneeBarCompanionFeature
import Testing

@MainActor
private func combinedCatalogue() throws -> CompanionAssetCatalog {
    let data = try #require(Data(base64Encoded: "R0lGODlhBAACAIEAAECA/wAAAAAAAAAAACH/C05FVFNDQVBFMi4wAwEAAAAh+QQACgAAACwAAAAABAACAAAIBwABCBwoMCAAIfkEARQAAQAsAAAAAAQAAgCB/0AAAAAAAAAAAAAACAcAAQgcKDAgADs="))
    let clip = try CompanionImageDecoder.decode(data)
    return try CompanionAssetCatalog(assets: [.run: clip], defaultState: .run)
}

@Test @MainActor func combinedHostOnlyCommittedSettingsReachBorrowedSurface() throws {
    let name = "SchneeBarTests.combinedHost.\(UUID())"
    let defaults = try #require(UserDefaults(suiteName: name))
    defer { defaults.removePersistentDomain(forName: name) }
    let store = CompanionHostPreferenceStore(defaults: defaults)
    let button = NSButton(title: " CPU 42%", target: nil, action: nil)
    button.image = NSImage(size: NSSize(width: 12, height: 12))
    button.toolTip = "CPU 42%"
    let original = try #require(button.image)
    let surface = CompanionStatusImageSurface()
    let token = surface.begin(on: button)
    let renderer = CompanionMenuBarRenderer(
        onFrame: { image in _ = surface.present(image, in: token) },
        onClear: { _ = surface.clear(in: token) }
    )
    let runtime = CompanionRuntimeCoordinator(renderer: renderer)
    let bridge = CompanionHostRuntimeBridge(store: store, runtime: runtime)
    defer { bridge.stop(); surface.end(token) }
    let editor = CompanionHostSettingsModel(store: store, onCommittedRefresh: { [weak bridge] in
        bridge?.refreshPreferences()
    })
    bridge.updateEnvironment(.init(releaseApproved: true, ownsMenuSurface: true))
    #expect(bridge.decision.availability == .disabled)
    editor.draft.enabled = true
    editor.draft.allowLocalEvents = true
    editor.draft.freeze = true
    #expect(bridge.decision.availability == .disabled)
    #expect(button.image === original)
    #expect(bridge.beginAssetRequest() == nil)
    editor.save()
    #expect(editor.notice == .saved)
    #expect(bridge.decision.availability == .awaitingCatalogue)
    let ticket = try #require(bridge.beginAssetRequest())
    #expect(bridge.completeAssetRequest(ticket, catalogue: try combinedCatalogue()))
    #expect(button.image !== original)
    #expect(button.title == " CPU 42%" && button.toolTip == "CPU 42%")
    #expect(runtime.displayedFrameIndex == 0 && !runtime.wantsHostCPU)
    #expect(runtime.localEventSession != nil)
    editor.draft.enabled = false
    #expect(bridge.decision.rendersCharacter)
    editor.discardEdits()
    #expect(editor.draft.enabled && bridge.decision.rendersCharacter)
    editor.draft.enabled = false
    editor.save()
    #expect(bridge.decision.availability == .disabled)
    #expect(button.image === original)
    #expect(!runtime.wantsHostCPU && runtime.localEventSession == nil)
    #expect(!bridge.completeAssetRequest(ticket, catalogue: nil))
}

@Test @MainActor func combinedHostRecoveryAndRevocationRestoreImage() throws {
    let name = "SchneeBarTests.combinedHost.\(UUID())"
    let defaults = try #require(UserDefaults(suiteName: name))
    defer { defaults.removePersistentDomain(forName: name) }
    let store = CompanionHostPreferenceStore(defaults: defaults)
    try store.save(.init(enabled: true, allowLocalEvents: true))
    let button = NSButton()
    button.image = NSImage(size: NSSize(width: 12, height: 12))
    let original = try #require(button.image)
    let surface = CompanionStatusImageSurface()
    let token = surface.begin(on: button)
    let runtime = CompanionRuntimeCoordinator(renderer: CompanionMenuBarRenderer(
        onFrame: { image in _ = surface.present(image, in: token) },
        onClear: { _ = surface.clear(in: token) }
    ))
    let bridge = CompanionHostRuntimeBridge(store: store, runtime: runtime)
    defer { bridge.stop(); surface.end(token) }
    let editor = CompanionHostSettingsModel(store: store, onCommittedRefresh: { [weak bridge] in
        bridge?.refreshPreferences()
    })
    let catalogue = try combinedCatalogue()
    #expect(bridge.decision.availability == .releaseBlocked)
    bridge.updateEnvironment(.init(releaseApproved: true, ownsMenuSurface: true, systemReduceMotion: true))
    let first = try #require(bridge.beginAssetRequest())
    #expect(bridge.completeAssetRequest(first, catalogue: catalogue))
    #expect(button.image !== original)
    let pending = try #require(bridge.beginAssetRequest())
    defaults.set(Data("broken".utf8), forKey: CompanionHostPreferenceStore.storageKey)
    editor.reload()
    #expect(editor.requiresRecovery && !editor.canSave)
    #expect(bridge.decision.availability == .disabled && button.image === original)
    #expect(!bridge.completeAssetRequest(pending, catalogue: catalogue))
    editor.requestReset()
    editor.confirmReset(try #require(editor.resetConfirmation))
    #expect(store.load() == .missing)
    #expect(button.image === original && !bridge.decision.rendersCharacter)
    editor.draft.enabled = true
    editor.save()
    let next = try #require(bridge.beginAssetRequest())
    #expect(bridge.completeAssetRequest(next, catalogue: catalogue))
    #expect(button.image !== original)
    bridge.updateEnvironment(.init())
    #expect(bridge.decision.availability == .releaseBlocked)
    #expect(button.image === original)
    #expect(!runtime.wantsHostCPU && runtime.localEventSession == nil)
}

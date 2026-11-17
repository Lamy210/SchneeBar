import AppKit
import CoreGraphics
import Foundation
import ImageIO
import SchneeBarCompanionAssets
import SchneeBarCompanionCore
import SchneeBarCompanionEvents
@testable import SchneeBarCompanionFeature
import Testing
import UniformTypeIdentifiers

@MainActor
private func renderFixture(animated: Bool = false) throws -> CompanionDecodedClip {
    if animated {
        // Independent fixed GIF, not an encoder-dependent identical frame pair.
        let data = try #require(Data(base64Encoded: "R0lGODlhBAACAIEAAECA/wAAAAAAAAAAACH/C05FVFNDQVBFMi4wAwEAAAAh+QQACgAAACwAAAAABAACAAAIBwABCBwoMCAAIfkEARQAAQAsAAAAAAQAAgCB/0AAAAAAAAAAAAAACAcAAQgcKDAgADs="))
        let decoded = try CompanionImageDecoder.decode(data)
        try #require(decoded.frames.count == 2)
        return decoded
    }
    let context = try #require(CGContext(
        data: nil, width: 4, height: 2, bitsPerComponent: 8, bytesPerRow: 16,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ))
    context.setFillColor(red: 0, green: 0.5, blue: 1, alpha: 1)
    context.fill(CGRect(x: 0, y: 0, width: 4, height: 2))
    let image = try #require(context.makeImage())
    let data = NSMutableData()
    let destination = try #require(CGImageDestinationCreateWithData(
        data as CFMutableData, UTType.png.identifier as CFString, 1, nil
    ))
    CGImageDestinationAddImage(destination, image, nil)
    #expect(CGImageDestinationFinalize(destination))
    return try CompanionImageDecoder.decode(data as Data)
}

@Test @MainActor func menuRendererStaticClipAndIdempotentStop() throws {
    var images: [NSImage] = []
    var clears = 0
    let renderer = CompanionMenuBarRenderer(onFrame: { images.append($0) }, onClear: { clears += 1 })
    let fixture = try renderFixture()
    renderer.setReduceMotion(true)
    renderer.install(fixture)
    renderer.install(fixture)
    #expect(images.count == 1)
    #expect(images.first?.size.width == 18)
    #expect(images.first?.size.height == 9)
    #expect(renderer.displayedFrameIndex == 0)
    renderer.stop()
    renderer.stop()
    #expect(clears == 1)
    #expect(renderer.displayedFrameIndex == nil)
}

@MainActor
private final class ManualFrameScheduler {
    private(set) var delays: [Double] = []
    private var callbacks: [@MainActor () -> Void] = []

    func schedule(_ delay: Double, callback: @escaping @MainActor () -> Void) -> Task<Void, Never> {
        delays.append(delay)
        callbacks.append(callback)
        return Task {}
    }

    // Intentionally invoke even cancelled or previously consumed callbacks.
    func fire(_ index: Int) {
        guard callbacks.indices.contains(index) else {
            Issue.record("Missing scheduled callback at index \(index)")
            return
        }
        callbacks[index]()
    }
}

@Test @MainActor func rendererFencesOldAndDuplicateCallbacks() throws {
    let fake = ManualFrameScheduler()
    var frames = 0
    var clears = 0
    let renderer = CompanionMenuBarRenderer(
        onFrame: { _ in frames += 1 }, onClear: { clears += 1 },
        scheduler: { delay, callback in fake.schedule(delay, callback: callback) }
    )
    let asset = try renderFixture(animated: true)
    renderer.install(asset)
    #expect(frames == 1)
    #expect(fake.delays.count == 1)
    fake.fire(0)
    #expect(renderer.displayedFrameIndex == 1)
    #expect(frames == 2)
    fake.fire(0)
    #expect(frames == 2)
    renderer.setRate(.double)
    #expect(renderer.displayedFrameIndex == 1)
    try #require(fake.delays.count == 3)
    #expect(abs(fake.delays[2] - 0.1) < 0.011)
    fake.fire(1)
    #expect(frames == 2)
    renderer.setReduceMotion(true)
    fake.fire(2)
    #expect(frames == 2)
    renderer.setReduceMotion(false)
    #expect(fake.delays.count == 4)
    fake.fire(3)
    #expect(renderer.displayedFrameIndex == 0)
    #expect(frames == 3)
    renderer.stop()
    fake.fire(4)
    #expect(frames == 3)
    #expect(clears == 1)
}

@Test @MainActor func coordinatorOptInCPUManualStateAndSleep() throws {
    var frames = 0
    var clears = 0
    let renderer = CompanionMenuBarRenderer(onFrame: { _ in frames += 1 }, onClear: { clears += 1 })
    let runtime = CompanionRuntimeCoordinator(renderer: renderer)
    let asset = try renderFixture()
    let catalogue = try CompanionAssetCatalog(assets: [.run: asset], defaultState: .run)
    runtime.setCatalog(catalogue)
    #expect(frames == 0)
    #expect(!runtime.wantsHostCPU)
    runtime.setPresentation(enabled: true, visible: true, awake: true, reduceMotion: false)
    #expect(frames == 1)
    #expect(runtime.wantsHostCPU)
    let first = try #require(runtime.beginCPURequest())
    let epoch = UUID()
    let time = ContinuousClock.now
    runtime.acceptCPU(first, id: UUID(), epoch: epoch, capturedAt: time, hostPercentage: 100)
    #expect(runtime.state == .sprint)
    #expect(runtime.rate == .double)
    #expect(frames == 1) // fallback resolves to the same clip
    runtime.setManualState(.idle)
    #expect(runtime.state == .idle)
    #expect(runtime.rate == .double)
    let stale = try #require(runtime.beginCPURequest())
    runtime.setMode(.manual(.half))
    #expect(!runtime.wantsHostCPU)
    #expect(runtime.state == .idle)
    #expect(runtime.rate == .half)
    runtime.acceptCPU(stale, id: UUID(), epoch: epoch, capturedAt: time, hostPercentage: 100)
    #expect(runtime.rate == .half)
    runtime.setManualState(nil)
    #expect(runtime.state == .run)
    runtime.setPresentation(enabled: true, visible: true, awake: false, reduceMotion: false)
    #expect(clears == 1)
    #expect(runtime.displayedFrameIndex == nil)
    runtime.setMode(.automatic)
    #expect(!runtime.wantsHostCPU)
    runtime.setPresentation(enabled: true, visible: true, awake: true, reduceMotion: false)
    #expect(runtime.wantsHostCPU)
    #expect(runtime.rate == .normal)
    #expect(frames == 2)
}

@Test @MainActor func coordinatorReducedMotionAndAssetRemovalFenceCPU() throws {
    let renderer = CompanionMenuBarRenderer(onFrame: { _ in }, onClear: {})
    let runtime = CompanionRuntimeCoordinator(renderer: renderer)
    let asset = try renderFixture()
    runtime.setCatalog(try CompanionAssetCatalog(assets: [.run: asset], defaultState: .run))
    runtime.setPresentation(enabled: true, visible: true, awake: true, reduceMotion: false)
    let pending = try #require(runtime.beginCPURequest())
    runtime.setPresentation(enabled: true, visible: true, awake: true, reduceMotion: true)
    #expect(!runtime.wantsHostCPU)
    #expect(runtime.displayedFrameIndex == 0)
    runtime.acceptCPU(pending, id: UUID(), epoch: UUID(), capturedAt: .now, hostPercentage: 100)
    #expect(runtime.state == .run)
    #expect(runtime.rate == .normal)
    runtime.setCatalog(nil)
    #expect(runtime.displayedFrameIndex == nil)
    #expect(!runtime.wantsHostCPU)
}

@Test @MainActor func coordinatorReducedMotionResolvesStaticFallbackOnDistinctClip() throws {
    var frames = 0
    let fake = ManualFrameScheduler()
    let renderer = CompanionMenuBarRenderer(onFrame: { _ in frames += 1 }, onClear: {},
        scheduler: { delay, callback in fake.schedule(delay, callback: callback) })
    let runtime = CompanionRuntimeCoordinator(renderer: renderer)
    let run = try renderFixture()
    let sprint = try renderFixture(animated: true)
    runtime.setCatalog(try CompanionAssetCatalog(assets: [.run: run, .sprint: sprint], defaultState: .run))
    runtime.setPresentation(enabled: true, visible: true, awake: true, reduceMotion: false)
    let request = try #require(runtime.beginCPURequest())
    runtime.acceptCPU(request, id: UUID(), epoch: UUID(), capturedAt: .now, hostPercentage: 100)
    #expect(runtime.state == .sprint)
    #expect(fake.delays.count == 1)
    fake.fire(0)
    #expect(runtime.displayedFrameIndex == 1)
    runtime.setPresentation(enabled: true, visible: true, awake: true, reduceMotion: true)
    #expect(runtime.state == .run)
    #expect(runtime.displayedFrameIndex == 0)
    #expect(!runtime.wantsHostCPU)
    let previousCount = frames
    fake.fire(1)
    #expect(frames == previousCount)
}

@MainActor
private final class LocalDeadlineFixture {
    var now: Duration = .zero
    private(set) var delays: [Duration] = []
    private var callbacks: [@MainActor () -> Void] = []

    func schedule(_ delay: Duration, _ callback: @escaping @MainActor () -> Void) -> Task<Void, Never> {
        delays.append(delay)
        callbacks.append(callback)
        return Task {}
    }

    func fire(_ index: Int) {
        guard callbacks.indices.contains(index) else {
            Issue.record("Missing deadline callback")
            return
        }
        callbacks[index]()
    }
}

@Test @MainActor func localEventsOptInRenewAndExpireWithoutCPUPolling() throws {
    let clock = LocalDeadlineFixture()
    let renderer = CompanionMenuBarRenderer(onFrame: { _ in }, onClear: {})
    let runtime = CompanionRuntimeCoordinator(renderer: renderer, elapsed: { clock.now },
        deadlineScheduler: { clock.schedule($0, $1) })
    let asset = try renderFixture()
    runtime.setCatalog(try CompanionAssetCatalog(assets: [.run: asset], defaultState: .run))
    runtime.setPresentation(enabled: true, visible: true, awake: true, reduceMotion: true)
    #expect(!runtime.wantsHostCPU)
    #expect(runtime.localEventSession == nil)
    let payload = Data("{\"phase\":\"succeeded\"}".utf8)
    #expect(runtime.receiveLocalEvent(session: UUID(), kind: .build, payload: payload) == nil)
    runtime.setLocalEventsEnabled(true)
    let session = try #require(runtime.localEventSession)
    #expect(runtime.receiveLocalEvent(session: session, kind: .build, payload: payload) == .accepted)
    #expect(runtime.state == .sprint)
    #expect(clock.delays == [.seconds(2)])
    clock.now = .seconds(1)
    #expect(runtime.receiveLocalEvent(session: session, kind: .build, payload: payload) == .accepted)
    #expect(clock.delays == [.seconds(2), .seconds(2)])
    clock.now = .seconds(2)
    clock.fire(0)
    #expect(runtime.state == .sprint)
    clock.now = .seconds(3)
    clock.fire(1)
    #expect(runtime.state == .run)
    clock.fire(1)
    #expect(runtime.state == .run)
    #expect(clock.delays.count == 2)
}

@Test @MainActor func localEventSessionFencesSleepDisableAndPreservesManualState() throws {
    let clock = LocalDeadlineFixture()
    let renderer = CompanionMenuBarRenderer(onFrame: { _ in }, onClear: {})
    let runtime = CompanionRuntimeCoordinator(renderer: renderer, elapsed: { clock.now },
        deadlineScheduler: { clock.schedule($0, $1) })
    let asset = try renderFixture()
    runtime.setCatalog(try CompanionAssetCatalog(assets: [.run: asset], defaultState: .run))
    runtime.setPresentation(enabled: true, visible: true, awake: true, reduceMotion: true)
    runtime.setLocalEventsEnabled(true)
    let first = try #require(runtime.localEventSession)
    let payload = Data("{\"phase\":\"started\"}".utf8)
    #expect(runtime.receiveLocalEvent(session: first, kind: .build, payload: payload) == .accepted)
    runtime.setManualState(.idle)
    #expect(runtime.state == .idle)
    runtime.setPresentation(enabled: true, visible: true, awake: false, reduceMotion: true)
    #expect(runtime.localEventSession == nil)
    clock.fire(0)
    #expect(runtime.state == .idle)
    runtime.setPresentation(enabled: true, visible: true, awake: true, reduceMotion: true)
    let second = try #require(runtime.localEventSession)
    #expect(second != first)
    runtime.setManualState(nil)
    #expect(runtime.state == .run)
    #expect(runtime.receiveLocalEvent(session: first, kind: .build, payload: payload) == nil)
    #expect(runtime.receiveLocalEvent(session: second, kind: .build, payload: payload) == .accepted)
    runtime.setLocalEventsEnabled(false)
    #expect(runtime.state == .run)
    #expect(runtime.localEventSession == nil)
    #expect(runtime.receiveLocalEvent(session: second, kind: .build, payload: payload) == nil)
}

@Test @MainActor func hostBridgeRequiresCommittedIntentAndApproval() throws {
    let name = "SchneeBarTests.hostBridge.\(UUID())"
    let defaults = try #require(UserDefaults(suiteName: name))
    defer { defaults.removePersistentDomain(forName: name) }
    let store = CompanionHostPreferenceStore(defaults: defaults)
    var frames = 0
    let runtime = CompanionRuntimeCoordinator(renderer: CompanionMenuBarRenderer(
        onFrame: { _ in frames += 1 }, onClear: {}))
    let bridge = CompanionHostRuntimeBridge(store: store, runtime: runtime)
    try store.save(.init(enabled: true, allowLocalEvents: true))
    bridge.refreshPreferences()
    #expect(bridge.decision.availability == .releaseBlocked)
    #expect(bridge.beginAssetRequest() == nil)
    #expect(!runtime.wantsHostCPU && runtime.localEventSession == nil)
    bridge.updateEnvironment(.init(releaseApproved: true, ownsMenuSurface: true))
    #expect(bridge.decision.availability == .awaitingCatalogue)
    #expect(frames == 0)
    let request = try #require(bridge.beginAssetRequest())
    let catalog = try CompanionAssetCatalog(assets: [.run: renderFixture()], defaultState: .run)
    #expect(bridge.completeAssetRequest(request, catalogue: catalog))
    #expect(frames == 1 && runtime.wantsHostCPU && runtime.localEventSession != nil)
    defaults.set("invalid", forKey: CompanionHostPreferenceStore.storageKey)
    bridge.refreshPreferences()
    #expect(bridge.decision.availability == .disabled)
    #expect(runtime.displayedFrameIndex == nil && !runtime.wantsHostCPU && runtime.localEventSession == nil)
}

@Test @MainActor func hostBridgeLatestAssetRequestAndLifecycleFence() throws {
    let name = "SchneeBarTests.hostBridge.\(UUID())"
    let defaults = try #require(UserDefaults(suiteName: name))
    defer { defaults.removePersistentDomain(forName: name) }
    let store = CompanionHostPreferenceStore(defaults: defaults)
    try store.save(.init(enabled: true))
    let runtime = CompanionRuntimeCoordinator(renderer: CompanionMenuBarRenderer(onFrame: { _ in }, onClear: {}))
    let bridge = CompanionHostRuntimeBridge(store: store, runtime: runtime)
    let catalog = try CompanionAssetCatalog(assets: [.run: renderFixture()], defaultState: .run)
    bridge.updateEnvironment(.init(releaseApproved: true, ownsMenuSurface: true))
    let old = try #require(bridge.beginAssetRequest())
    let latest = try #require(bridge.beginAssetRequest())
    #expect(!bridge.completeAssetRequest(old, catalogue: catalog))
    #expect(bridge.completeAssetRequest(latest, catalogue: catalog))
    #expect(!bridge.completeAssetRequest(latest, catalogue: nil))
    let replacement = try #require(bridge.beginAssetRequest())
    let cpu = try #require(runtime.beginCPURequest())
    bridge.updateEnvironment(.init(releaseApproved: true, awake: false, ownsMenuSurface: true))
    #expect(runtime.displayedFrameIndex == nil)
    #expect(!bridge.completeAssetRequest(replacement, catalogue: catalog))
    bridge.updateEnvironment(.init(releaseApproved: true, ownsMenuSurface: true))
    #expect(bridge.decision.availability == .awaitingCatalogue)
    let fresh = try #require(bridge.beginAssetRequest())
    #expect(bridge.completeAssetRequest(fresh, catalogue: catalog))
    runtime.acceptCPU(cpu, id: UUID(), epoch: UUID(), capturedAt: .now, hostPercentage: 100)
    #expect(runtime.rate == .normal)
    bridge.stop()
    #expect(bridge.decision.availability == .releaseBlocked && runtime.displayedFrameIndex == nil)
}

@Test @MainActor func hostBridgeAppliesMotionAndEventPolicyWithoutTransientActivation() throws {
    let name = "SchneeBarTests.hostBridge.\(UUID())"
    let defaults = try #require(UserDefaults(suiteName: name))
    defer { defaults.removePersistentDomain(forName: name) }
    let store = CompanionHostPreferenceStore(defaults: defaults)
    try store.save(.init(enabled: true, speed: .half, allowLocalEvents: true))
    let scheduler = ManualFrameScheduler()
    let renderer = CompanionMenuBarRenderer(onFrame: { _ in }, onClear: {},
        scheduler: { delay, callback in scheduler.schedule(delay, callback: callback) })
    let runtime = CompanionRuntimeCoordinator(renderer: renderer)
    let bridge = CompanionHostRuntimeBridge(store: store, runtime: runtime)
    bridge.updateEnvironment(.init(releaseApproved: true, ownsMenuSurface: true, systemReduceMotion: true))
    let catalog = try CompanionAssetCatalog(assets: [.run: renderFixture(animated: true)], defaultState: .run)
    #expect(bridge.completeAssetRequest(try #require(bridge.beginAssetRequest()), catalogue: catalog))
    #expect(runtime.displayedFrameIndex == 0 && scheduler.delays.isEmpty && !runtime.wantsHostCPU)
    let first = try #require(runtime.localEventSession)
    bridge.updateEnvironment(.init(releaseApproved: true, ownsMenuSurface: true))
    #expect(runtime.rate == .half && !runtime.wantsHostCPU)
    #expect(!scheduler.delays.isEmpty)
    #expect(runtime.localEventSession == first)
    #expect(bridge.completeAssetRequest(try #require(bridge.beginAssetRequest()), catalogue: catalog))
    #expect(runtime.localEventSession != nil && runtime.localEventSession != first)
    #expect(runtime.receiveLocalEvent(session: first, kind: .build, payload: Data("{\"phase\":\"started\"}".utf8)) == nil)
    try store.save(.init(enabled: true, allowLocalEvents: true, preset: .minimal))
    bridge.refreshPreferences()
    #expect(bridge.decision.availability == .hidden && runtime.localEventSession == nil)
    #expect(!runtime.wantsHostCPU && runtime.displayedFrameIndex == nil)
    bridge.stop()
}

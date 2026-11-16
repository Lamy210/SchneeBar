import AppKit
import CoreGraphics
import Foundation
import ImageIO
import SchneeBarCompanionAssets
import SchneeBarCompanionCore
@testable import SchneeBarCompanionFeature
import Testing
import UniformTypeIdentifiers

@MainActor
private func renderFixture(animated: Bool = false) throws -> CompanionDecodedClip {
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
        data as CFMutableData,
        (animated ? UTType.gif : UTType.png).identifier as CFString,
        animated ? 2 : 1, nil
    ))
    if animated {
        CGImageDestinationAddImage(destination, image,
            [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: 0.1]] as CFDictionary)
        CGImageDestinationAddImage(destination, image,
            [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: 0.2]] as CFDictionary)
    } else {
        CGImageDestinationAddImage(destination, image, nil)
    }
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
    #expect(fake.delays.count == 3)
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

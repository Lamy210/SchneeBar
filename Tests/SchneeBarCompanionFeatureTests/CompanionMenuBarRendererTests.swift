import AppKit
import CoreGraphics
import Foundation
import ImageIO
import SchneeBarCompanionAssets
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

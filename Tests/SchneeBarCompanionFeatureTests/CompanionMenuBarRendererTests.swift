import AppKit
import CoreGraphics
import Foundation
import ImageIO
import SchneeBarCompanionAssets
import SchneeBarCompanionFeature
import Testing
import UniformTypeIdentifiers

@MainActor
private func renderFixture() throws -> CompanionDecodedClip {
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

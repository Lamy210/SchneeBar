import CoreGraphics
import Foundation
import SchneeBarCompanionCore
@testable import SchneeBarCompanionAssets
import Testing

// Independent 9x5 PNG: eight solid-color cells, distinct red values.
private let spriteData = "iVBORw0KGgoAAAANSUhEUgAAAAkAAAAFCAYAAACXU8ZrAAAAJ0lEQVR4nGNU0Djxn4GBgUGCAQLQaQYGBgYmBiIASwIOE0g2iShFAO5GAwui1pxIAAAAAElFTkSuQmCC"

private func withStaticPack(kind: String, body: (URL) throws -> Void) throws {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString + ".schneerunner", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
    defer { try? FileManager.default.removeItem(at: url) }
    try #require(Data(base64Encoded: spriteData)).write(to: url.appendingPathComponent("sprite.png"))
    let manifest = """
    {"formatVersion":1,"name":"Static test","defaultState":"run","clips":[{"state":"run","kind":"\(kind)","path":"sprite.png"}]}
    """
    try Data(manifest.utf8).write(to: url.appendingPathComponent("character.json"))
    try body(url)
}

private func rgba(_ image: CGImage) throws -> [UInt8] {
    var bytes = [UInt8](repeating: 0, count: 4)
    try bytes.withUnsafeMutableBytes { buffer in
        let canvas = try #require(CGContext(
            data: buffer.baseAddress, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue
        ))
        canvas.draw(image, in: CGRect(x: 0, y: 0, width: 1, height: 1))
    }
    return bytes
}

@Test func spritePackCoversOddDimensionsInRowMajorOrder() throws {
    try withStaticPack(kind: "spriteSheet4x2") { url in
        let asset = try CompanionAnimatedPackLoader.load(url).asset(for: .run)
        try #require(asset.frames.count == 8)
        #expect(asset.frames.map(\.width) == [2, 2, 2, 3, 2, 2, 2, 3])
        #expect(asset.frames.map(\.height) == [2, 2, 2, 2, 3, 3, 3, 3])
        #expect(asset.frames.reduce(0) { $0 + $1.width * $1.height } == 45)
        let reds = try asset.frames.map { try rgba($0)[0] }
        #expect(zip(reds, [32, 56, 80, 104, 128, 152, 176, 200]).allSatisfy {
            abs(Int($0.0) - $0.1) <= 3
        })
        #expect(asset.clip.durations == Array(repeating: 1.0 / 12.0, count: 8))
    }
}

@Test func staticSourceAndGeneratedOutputBothConsumeBudget() throws {
    try withStaticPack(kind: "spriteSheet4x2") { url in
        #expect(throws: CompanionAnimatedPackError.frameBudget) {
            try CompanionAnimatedPackLoader.load(url, limits: .init(frames: 7))
        }
        #expect(throws: CompanionAnimatedPackError.pixelBudget) {
            try CompanionAnimatedPackLoader.load(url, limits: .init(pixels: 89))
        }
        let value = try CompanionAnimatedPackLoader.load(url, limits: .init(frames: 8, pixels: 90))
        #expect(value.asset(for: .run).frames.count == 8)
    }
}

@Test func singlePNGProducesFixedBoundedIndependentFrames() throws {
    try withStaticPack(kind: "singleImage") { url in
        let limit = 45 + 8 * 128 * 64
        #expect(throws: CompanionAnimatedPackError.pixelBudget) {
            try CompanionAnimatedPackLoader.load(url, limits: .init(pixels: limit - 1))
        }
        let value = try CompanionAnimatedPackLoader.load(url, limits: .init(pixels: limit))
        let asset = value.asset(for: .run)
        #expect(asset.frames.count == 8)
        #expect(asset.frames.allSatisfy { $0.width == 128 && $0.height == 64 })
        #expect(asset.clip.durations == Array(repeating: 1.0 / 12.0, count: 8))
        #expect(value.asset(for: .sprint).clip == asset.clip)
    }
}

@Test func staticPackRejectsAnimatedPNGAndSmallSprite() throws {
    try withStaticPack(kind: "spriteSheet4x2") { url in
        let apng = try #require(Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAQAAAACCAYAAAB/qH1jAAAACGFjVEwAAAACAAAAAPONk3AAAAAaZmNUTAAAAAAAAAAEAAAAAgAAAAAAAAAAAAEACgAAdYjXEwAAABNJREFUeJxj/M/A8J8BCTAxoAEAPycCAuqcPLEAAAAaZmNUTAAAAAEAAAAEAAAAAgAAAAAAAAAAAAEABQAA5ad6+gAAABdmZEFUAAAAAnicY2Ro+P+fAQkwMaABAE0pAoJQdSdOAAAAAElFTkSuQmCC"))
        try apng.write(to: url.appendingPathComponent("sprite.png"))
        #expect(throws: CompanionAnimatedPackError.frameBudget) {
            try CompanionAnimatedPackLoader.load(url)
        }
    }
    #expect(throws: CompanionImageError.invalidDimensions) {
        try CompanionStaticPackClip.outputPixels(.spriteSheet4x2, width: 3, height: 2)
    }
}

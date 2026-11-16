import CoreGraphics
import Foundation
import ImageIO
@testable import SchneeBarCompanionAssets
import Testing
import UniformTypeIdentifiers

private func testImage() throws -> CGImage {
    let context = try #require(CGContext(
        data: nil, width: 4, height: 2, bitsPerComponent: 8, bytesPerRow: 16,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ))
    context.setFillColor(red: 0.25, green: 0.5, blue: 1, alpha: 1)
    context.fill(CGRect(x: 0, y: 0, width: 4, height: 2))
    return try #require(context.makeImage())
}

private func fixture(type: UTType, durations: [Double]) throws -> Data {
    let data = NSMutableData()
    let destination = try #require(CGImageDestinationCreateWithData(
        data as CFMutableData, type.identifier as CFString, durations.count, nil
    ))
    let image = try testImage()
    for duration in durations {
        let options = type == .gif
            ? [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: duration]] as CFDictionary
            : nil
        CGImageDestinationAddImage(destination, image, options)
    }
    #expect(CGImageDestinationFinalize(destination))
    return data as Data
}

@Test func staticPNGProducesOneBoundedFrame() throws {
    let decoded = try CompanionImageDecoder.decode(fixture(type: .png, durations: [0.1]))
    #expect(decoded.frames.count == 1)
    #expect(decoded.frames[0].width == 4)
    #expect(decoded.frames[0].height == 2)
    #expect(decoded.frames[0].bitsPerComponent == 8)
    #expect(decoded.clip.durations.count == 1)
}

@Test func animatedGIFPreservesAuthoredDelays() throws {
    // Fixed independent GIF89a: two distinct 4x2 solid-color frames, 100/200 ms.
    let data = try #require(Data(base64Encoded: "R0lGODlhBAACAIEAAECA/wAAAAAAAAAAACH/C05FVFNDQVBFMi4wAwEAAAAh+QQACgAAACwAAAAABAACAAAIBwABCBwoMCAAIfkEARQAAQAsAAAAAAQAAgCB/0AAAAAAAAAAAAAACAcAAQgcKDAgADs="))
    let source = try #require(CGImageSourceCreateWithData(data as CFData, nil))
    try #require(CGImageSourceGetCount(source) == 2)
    let decoded = try CompanionImageDecoder.decode(data)
    try #require(decoded.frames.count == 2)
    try #require(decoded.clip.durations.count == 2)
    #expect(abs(decoded.clip.durations[0] - 0.1) < 0.011)
    #expect(abs(decoded.clip.durations[1] - 0.2) < 0.011)
}

@Test func rejectsEmptyOversizedAndUnsupportedData() throws {
    #expect(throws: CompanionImageError.invalidPayload) {
        try CompanionImageDecoder.decode(Data())
    }
    #expect(throws: CompanionImageError.invalidPayload) {
        try CompanionImageDecoder.decode(Data(repeating: 0, count: CompanionImageDecoder.maximumBytes + 1))
    }
    let jpeg = try fixture(type: .jpeg, durations: [0.1])
    #expect(throws: CompanionImageError.unsupportedFormat) {
        try CompanionImageDecoder.decode(jpeg)
    }
}

@Test func dimensionAndAggregatePixelLimitsAreCheckedBeforeMultiplication() throws {
    var total = 0
    #expect(throws: CompanionImageError.invalidDimensions) {
        try CompanionImageDecoder.account(width: Int.max, height: Int.max, total: &total)
    }
    try CompanionImageDecoder.account(width: 4000, height: 4000, total: &total)
    #expect(total == 16_000_000)
    #expect(throws: CompanionImageError.pixelBudget) {
        try CompanionImageDecoder.account(width: 1, height: 1, total: &total)
    }
    #expect(total == 16_000_000)
}

@Test func catalogRequiresDefaultAndResolvesAliases() throws {
    let asset = try CompanionImageDecoder.decode(fixture(type: .png, durations: [0.1]))
    #expect(throws: CompanionAssetCatalogError.missingDefault) {
        try CompanionAssetCatalog(assets: [.idle: asset], defaultState: .run)
    }
    let catalog = try CompanionAssetCatalog(assets: [.run: asset, .idle: asset], defaultState: .run)
    #expect(catalog.asset(for: .sprint).clip == asset.clip)
    #expect(catalog.asset(for: .idle).clip == asset.clip)
}

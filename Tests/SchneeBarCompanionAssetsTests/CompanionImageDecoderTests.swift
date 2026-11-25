import CoreGraphics
import Foundation
import ImageIO
import SchneeBarCompanionCore
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

@Test func originalPreviewCatalogueHasBoundedDistinctStateClips() throws {
    let catalogue = try CompanionPreviewAssets.catalogue()
    let states: [SchneeBarCompanionCore.CompanionState] = [.idle, .walk, .run, .dash, .sprint]
    var ids: Set<UUID> = []
    for state in states {
        let decoded = catalogue.asset(for: state)
        ids.insert(decoded.clip.revision)
        #expect(decoded.frames.count == 2)
        #expect(decoded.frames.allSatisfy { $0.width == 32 && $0.height == 32 })
    }
    #expect(ids.count == 5)
}

@Test func originalPreviewFramesRetainTransparentBorderAtEveryState() throws {
    let catalogue = try CompanionPreviewAssets.catalogue()
    let states: [CompanionState] = [.idle, .walk, .run, .dash, .sprint]
    for state in states {
        for frame in catalogue.asset(for: state).frames {
            try #require(frame.width == 32 && frame.height == 32)
            var pixels = [UInt8](repeating: 0, count: 32 * 32 * 4)
            try pixels.withUnsafeMutableBytes { bytes in
                let context = try #require(CGContext(
                    data: bytes.baseAddress, width: 32, height: 32,
                    bitsPerComponent: 8, bytesPerRow: 128,
                    space: CGColorSpaceCreateDeviceRGB(),
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                        | CGBitmapInfo.byteOrder32Big.rawValue
                ))
                context.clear(CGRect(x: 0, y: 0, width: 32, height: 32))
                context.draw(frame, in: CGRect(x: 0, y: 0, width: 32, height: 32))
            }
            var visible = false
            for y in 0..<32 {
                for x in 0..<32 {
                    let alpha = pixels[(y * 32 + x) * 4 + 3]
                    if x == 0 || x == 31 || y == 0 || y == 31 {
                        #expect(alpha == 0)
                    } else if alpha != 0 { visible = true }
                }
            }
            #expect(visible)
        }
    }
}

@Test @MainActor func singleFileImporterComposesReaderDecoderAndCatalogWithoutReplacingOnFailure() async throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("companion-import-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
    defer { try? FileManager.default.removeItem(at: directory) }

    let valid = directory.appendingPathComponent("valid.png")
    try fixture(type: .png, durations: [0.1]).write(to: valid)
    let malformed = directory.appendingPathComponent("broken.png")
    try Data([1, 2, 3, 4]).write(to: malformed)
    let link = directory.appendingPathComponent("link.png")
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: valid)

    let queue = CompanionSingleFileImporter.makeQueue()
    defer { queue.cancel() }
    var installed: CompanionAssetCatalog?
    var errors = 0
    for url in [valid, malformed, link] {
        queue.submit(url) { result in
            switch result {
            case let .success(catalogue): installed = catalogue
            case .failure: errors += 1
            }
        }
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while queue.isBusy {
            guard ContinuousClock.now < deadline else { throw CancellationError() }
            try await Task.sleep(for: .milliseconds(10))
        }
        let current = try #require(installed)
        let asset = current.asset(for: .run)
        try #require(asset.frames.count == 1)
        #expect(asset.frames[0].width == 4)
        #expect(asset.frames[0].height == 2)
        #expect(current.asset(for: .sprint).clip.revision == asset.clip.revision)
        if url == valid { #expect(errors == 0) }
    }
    #expect(errors == 2)
}


@Test func packThumbnailDownscalesDefaultClipWithoutRetainingSourceDimensions() throws {
    let canvas = try #require(CGContext(data: nil, width: 512, height: 256,
        bitsPerComponent: 8, bytesPerRow: 512 * 4, space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
    canvas.setFillColor(red: 0.25, green: 0.5, blue: 1, alpha: 1)
    canvas.fill(CGRect(x: 0, y: 0, width: 512, height: 256))
    let source = try #require(canvas.makeImage())
    let data = NSMutableData()
    let destination = try #require(CGImageDestinationCreateWithData(
        data as CFMutableData, UTType.png.identifier as CFString, 1, nil))
    CGImageDestinationAddImage(destination, source, nil)
    try #require(CGImageDestinationFinalize(destination))
    let large = try CompanionImageDecoder.decode(data as Data)
    let small = try CompanionImageDecoder.decode(fixture(type: .png, durations: [0.1]))
    let catalogue = try CompanionAssetCatalog(assets: [.idle: large, .run: small], defaultState: .idle)
    let thumbnail = try CompanionPackThumbnail(catalogue: catalogue)
    #expect(thumbnail.image.width == 128 && thumbnail.image.height == 64)
    #expect(thumbnail.image.bitsPerComponent == 8 && thumbnail.image.bytesPerRow == 128 * 4)
    #expect(catalogue.defaultAsset.frames[0].width == 512)
}

import CoreGraphics
import Foundation
import ImageIO
import SchneeBarCompanionCore
import UniformTypeIdentifiers

public enum CompanionImageError: Error, Equatable {
    case invalidPayload
    case unsupportedFormat
    case frameCount
    case invalidDimensions
    case pixelBudget
    case incompleteImage
    case decodeFailed
}

/// A validated in-memory clip; callers cannot construct mismatched frames/timing.
/// No file-system or URL authority enters this module.
// The only constructors create fully materialized, immutable CoreGraphics
// images backed by owned bitmap storage. No mutable context escapes.
public struct CompanionDecodedClip: @unchecked Sendable {
    public let clip: CompanionClip
    public let frames: [CGImage]

    init(clip: CompanionClip, frames: [CGImage]) {
        self.clip = clip
        self.frames = frames
    }
}

public enum CompanionImageDecoder {
    public static let maximumBytes = 32 * 1024 * 1024
    public static let maximumFrames = 120
    public static let maximumDimension = 4096
    public static let maximumTotalPixels = 16_000_000

    enum Format: Equatable {
        case png, gif, webp

        var timingKeys: (CFString, CFString, CFString) {
            switch self {
            case .png:
                (kCGImagePropertyPNGDictionary, kCGImagePropertyAPNGUnclampedDelayTime, kCGImagePropertyAPNGDelayTime)
            case .gif:
                (kCGImagePropertyGIFDictionary, kCGImagePropertyGIFUnclampedDelayTime, kCGImagePropertyGIFDelayTime)
            case .webp:
                (kCGImagePropertyWebPDictionary, kCGImagePropertyWebPUnclampedDelayTime, kCGImagePropertyWebPDelayTime)
            }
        }
    }

    /// Synchronous, bounded application-side admission. Platform decoders may
    /// still allocate internally; schedule off the UI path before production use.
    public static func decode(_ data: Data) throws -> CompanionDecodedClip {
        try decodePrepared(prepare(data))
    }

    /// Only used synchronously in one worker. Retains the exact ImageIO
    /// source inspected during preflight; never reopen an untrusted URL.
    struct Prepared {
        fileprivate let source: CGImageSource
        fileprivate let clip: CompanionClip
        let format: Format
        let metadataPixels: Int
        let firstWidth: Int
        let firstHeight: Int
        var frameCount: Int { clip.durations.count }
    }

    static func prepare(_ data: Data) throws -> Prepared {
        try Task.checkCancellation()
        guard !data.isEmpty, data.count <= maximumBytes else {
            throw CompanionImageError.invalidPayload
        }
        let options = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithData(data as CFData, options),
              let identifier = CGImageSourceGetType(source) as String? else {
            throw CompanionImageError.invalidPayload
        }
        let format: Format
        switch identifier {
        case UTType.png.identifier: format = .png
        case UTType.gif.identifier: format = .gif
        case UTType.webP.identifier: format = .webp
        default: throw CompanionImageError.unsupportedFormat
        }

        let count = CGImageSourceGetCount(source)
        guard (1...maximumFrames).contains(count) else {
            throw CompanionImageError.frameCount
        }
        guard CGImageSourceGetStatus(source) == .statusComplete else {
            throw CompanionImageError.incompleteImage
        }
        var metadataPixels = 0
        var firstWidth = 0
        var firstHeight = 0
        var durations: [Double] = []
        durations.reserveCapacity(count)
        // Validate all metadata before any explicit frame decode or allocation
        // of decoded frame storage. Recheck actual dimensions after decoding.
        for index in 0..<count {
            try Task.checkCancellation()
            guard let properties = CGImageSourceCopyPropertiesAtIndex(source, index, options) as? [CFString: Any],
                  let width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue,
                  let height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue else {
                throw CompanionImageError.invalidDimensions
            }
            try account(width: width, height: height, total: &metadataPixels)
            if index == 0 {
                firstWidth = width
                firstHeight = height
            }
            durations.append(frameDuration(properties, format: format))
        }
        let clip = try CompanionClip(revision: UUID(), durations: durations)
        return Prepared(source: source, clip: clip, format: format, metadataPixels: metadataPixels,
                        firstWidth: firstWidth, firstHeight: firstHeight)
    }

    static func decodePrepared(_ prepared: Prepared, pixelLimit: Int = maximumTotalPixels) throws -> CompanionDecodedClip {
        try Task.checkCancellation()
        guard (1...maximumTotalPixels).contains(pixelLimit),
              prepared.metadataPixels <= pixelLimit else { throw CompanionImageError.pixelBudget }
        let source = prepared.source
        let clip = prepared.clip
        let count = prepared.frameCount
        var decodedPixels = 0
        var frames: [CGImage] = []
        frames.reserveCapacity(count)
        for index in 0..<count {
            try Task.checkCancellation()
            guard CGImageSourceGetStatusAtIndex(source, index) == .statusComplete,
                  let image = CGImageSourceCreateImageAtIndex(
                    source, index, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary
                  ) else {
                throw CompanionImageError.decodeFailed
            }
            try account(width: image.width, height: image.height, total: &decodedPixels, limit: pixelLimit)
            // Bound the retained representation to RGBA8, including unusual
            // source bit depth/color spaces. Do not expose the source image.
            guard let context = CGContext(
                data: nil, width: image.width, height: image.height,
                bitsPerComponent: 8, bytesPerRow: image.width * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { throw CompanionImageError.decodeFailed }
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
            guard let normalized = context.makeImage() else {
                throw CompanionImageError.decodeFailed
            }
            frames.append(normalized)
        }
        try Task.checkCancellation()
        return CompanionDecodedClip(clip: clip, frames: frames)
    }

    static func account(width: Int, height: Int, total: inout Int, limit: Int = maximumTotalPixels) throws {
        guard (1...maximumDimension).contains(width), (1...maximumDimension).contains(height) else {
            throw CompanionImageError.invalidDimensions
        }
        // Both dimensions are validated before multiplying.
        let pixels = width * height
        guard (0...maximumTotalPixels).contains(limit), (0...limit).contains(total),
              pixels <= limit - total else {
            throw CompanionImageError.pixelBudget
        }
        total += pixels
    }

    private static func frameDuration(_ properties: [CFString: Any], format: Format) -> Double {
        let (dictionaryKey, unclampedKey, clampedKey) = format.timingKeys
        guard let timing = properties[dictionaryKey] as? [CFString: Any] else { return 0.1 }
        for key in [unclampedKey, clampedKey] {
            if let value = (timing[key] as? NSNumber)?.doubleValue, value.isFinite, value > 0 {
                return min(max(value, 0.02), 10)
            }
        }
        return 0.1
    }
}

/// Original, small procedural mascot for the developer-only preview. No
/// external assets, disk access, ImageIO input, or runtime decoding required.
public enum CompanionPreviewAssets {
    public static func catalogue() throws -> CompanionAssetCatalog {
        let states: [(CompanionState, Double, CGFloat)] = [
            (.idle, 0.5, 0), (.walk, 0.3, 1), (.run, 0.2, 2),
            (.dash, 0.12, 3), (.sprint, 0.08, 4)
        ]
        var assets: [CompanionState: CompanionDecodedClip] = [:]
        for (state, delay, lift) in states {
            let frames = try [frame(lift: 0), frame(lift: lift + 1)]
            let clip = try CompanionClip(revision: UUID(), durations: [delay, delay])
            assets[state] = CompanionDecodedClip(clip: clip, frames: frames)
        }
        return try CompanionAssetCatalog(assets: assets, defaultState: .run)
    }

    private static func frame(lift: CGFloat) throws -> CGImage {
        guard let canvas = CGContext(
            data: nil, width: 32, height: 32, bitsPerComponent: 8, bytesPerRow: 128,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { throw CompanionImageError.decodeFailed }
        canvas.clear(CGRect(x: 0, y: 0, width: 32, height: 32))
        // Original geometric snow creature: icy body, dark eyes, blue feet.
        canvas.setFillColor(red: 0.25, green: 0.48, blue: 0.76, alpha: 1)
        canvas.fillEllipse(in: CGRect(x: 5, y: 4 + lift, width: 10, height: 6))
        canvas.fillEllipse(in: CGRect(x: 17, y: 4 + lift, width: 10, height: 6))
        canvas.fillEllipse(in: CGRect(x: 3, y: 6 + lift, width: 26, height: 20))
        canvas.setFillColor(red: 0.83, green: 0.94, blue: 1, alpha: 1)
        canvas.fillEllipse(in: CGRect(x: 5, y: 8 + lift, width: 22, height: 16))
        canvas.setFillColor(red: 0.10, green: 0.22, blue: 0.40, alpha: 1)
        canvas.fillEllipse(in: CGRect(x: 10, y: 18 + lift, width: 3, height: 4))
        canvas.fillEllipse(in: CGRect(x: 19, y: 18 + lift, width: 3, height: 4))
        canvas.fillEllipse(in: CGRect(x: 14, y: 14 + lift, width: 4, height: 2))
        guard let image = canvas.makeImage() else { throw CompanionImageError.decodeFailed }
        return image
    }
}

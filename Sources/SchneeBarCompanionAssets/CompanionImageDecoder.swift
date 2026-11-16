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
public struct CompanionDecodedClip {
    public let clip: CompanionClip
    public let frames: [CGImage]

    fileprivate init(clip: CompanionClip, frames: [CGImage]) {
        self.clip = clip
        self.frames = frames
    }
}

public enum CompanionImageDecoder {
    public static let maximumBytes = 32 * 1024 * 1024
    public static let maximumFrames = 120
    public static let maximumDimension = 4096
    public static let maximumTotalPixels = 16_000_000

    private enum Format {
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
        var durations: [Double] = []
        durations.reserveCapacity(count)
        // Validate all metadata before any explicit frame decode or allocation
        // of decoded frame storage. Recheck actual dimensions after decoding.
        for index in 0..<count {
            guard let properties = CGImageSourceCopyPropertiesAtIndex(source, index, options) as? [CFString: Any],
                  let width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue,
                  let height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue else {
                throw CompanionImageError.invalidDimensions
            }
            try account(width: width, height: height, total: &metadataPixels)
            durations.append(frameDuration(properties, format: format))
        }
        let clip = try CompanionClip(revision: UUID(), durations: durations)

        var decodedPixels = 0
        var frames: [CGImage] = []
        frames.reserveCapacity(count)
        for index in 0..<count {
            guard CGImageSourceGetStatusAtIndex(source, index) == .statusComplete,
                  let image = CGImageSourceCreateImageAtIndex(
                    source, index, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary
                  ) else {
                throw CompanionImageError.decodeFailed
            }
            try account(width: image.width, height: image.height, total: &decodedPixels)
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
        return CompanionDecodedClip(clip: clip, frames: frames)
    }

    static func account(width: Int, height: Int, total: inout Int) throws {
        guard (1...maximumDimension).contains(width), (1...maximumDimension).contains(height) else {
            throw CompanionImageError.invalidDimensions
        }
        // Both dimensions are validated before multiplying.
        let pixels = width * height
        guard pixels <= maximumTotalPixels - total else {
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

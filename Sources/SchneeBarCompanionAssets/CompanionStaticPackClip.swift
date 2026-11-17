import CoreGraphics
import Foundation
import SchneeBarCompanionCore

/// A static PNG produces an eight-frame clip. The source and output are
/// both charged to the pack's conservative preflight/decode work budget.
enum CompanionStaticPackClip {
    static let frameCount = 8
    static let canvasWidth = 128
    static let canvasHeight = 64
    static let proceduralPixels = frameCount * canvasWidth * canvasHeight

    static func outputPixels(_ kind: CompanionPackManifest.Kind,
                             width: Int, height: Int) throws -> Int {
        switch kind {
        case .spriteSheet4x2:
            guard width >= 4, height >= 2 else { throw CompanionImageError.invalidDimensions }
            return width * height
        case .singleImage:
            return proceduralPixels
        default:
            throw CompanionAnimatedPackError.unsupportedKind
        }
    }

    static func make(_ prepared: CompanionImageDecoder.Prepared,
                     kind: CompanionPackManifest.Kind,
                     pixelLimit: Int) throws -> (clip: CompanionDecodedClip, chargedPixels: Int) {
        guard prepared.format == .png, prepared.frameCount == 1
        else { throw CompanionAnimatedPackError.formatMismatch }
        let output = try outputPixels(kind, width: prepared.firstWidth, height: prepared.firstHeight)
        guard output < pixelLimit, prepared.metadataPixels <= pixelLimit - output
        else { throw CompanionAnimatedPackError.pixelBudget }
        let decoded = try CompanionImageDecoder.decodePrepared(prepared, pixelLimit: pixelLimit - output)
        guard let source = decoded.frames.first,
              source.width == prepared.firstWidth, source.height == prepared.firstHeight else {
            throw CompanionImageError.invalidDimensions
        }
        let frames: [CGImage]
        switch kind {
        case .spriteSheet4x2: frames = try split(source)
        case .singleImage: frames = try animate(source)
        default: throw CompanionAnimatedPackError.unsupportedKind
        }
        try Task.checkCancellation()
        let clip = try CompanionClip(revision: UUID(), durations: Array(repeating: 1.0 / 12.0, count: frameCount))
        return (CompanionDecodedClip(clip: clip, frames: frames), source.width * source.height + output)
    }

    private static func split(_ source: CGImage) throws -> [CGImage] {
        var result: [CGImage] = []
        // Row-major from top-left in CGImage pixel coordinates; integer
        // boundaries cover odd dimensions without discarding edge pixels.
        for row in 0..<2 {
            for column in 0..<4 {
                try Task.checkCancellation()
                let x = column * source.width / 4
                let y = row * source.height / 2
                let width = (column + 1) * source.width / 4 - x
                let height = (row + 1) * source.height / 2 - y
                guard let crop = source.cropping(to: CGRect(x: x, y: y, width: width, height: height))
                else { throw CompanionImageError.decodeFailed }
                let canvas = try context(width: width, height: height)
                canvas.draw(crop, in: CGRect(x: 0, y: 0, width: width, height: height))
                guard let image = canvas.makeImage() else { throw CompanionImageError.decodeFailed }
                // Materialize owned storage rather than retaining eight crop
                // views of the original full-size bitmap.
                result.append(image)
            }
        }
        return result
    }

    private static func animate(_ source: CGImage) throws -> [CGImage] {
        // Independently authored bob cycle, not the original Runner motion
        // geometry. Fit inside a fixed safe canvas even for extreme aspect.
        let scale = min(104.0 / Double(source.width), 44.0 / Double(source.height))
        let width = max(1.0, Double(source.width) * scale)
        let height = max(1.0, Double(source.height) * scale)
        return try [0.0, 2, 5, 7, 5, 2, 0, 1].map { lift in
            try Task.checkCancellation()
            let canvas = try context(width: canvasWidth, height: canvasHeight)
            canvas.interpolationQuality = .high
            canvas.draw(source, in: CGRect(x: (Double(canvasWidth) - width) / 2,
                                          y: 5 + lift, width: width, height: height))
            guard let image = canvas.makeImage() else { throw CompanionImageError.decodeFailed }
            return image
        }
    }

    private static func context(width: Int, height: Int) throws -> CGContext {
        guard let context = CGContext(
            data: nil, width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { throw CompanionImageError.decodeFailed }
        context.clear(CGRect(x: 0, y: 0, width: width, height: height))
        return context
    }
}

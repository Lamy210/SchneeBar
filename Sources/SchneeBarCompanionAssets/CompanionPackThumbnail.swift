import CoreGraphics
import Foundation

/// Immutable, independently allocated RGBA8 bitmap. Does not retain the
/// full decoded catalogue or the source image's pixel storage.
public struct CompanionPackThumbnail: @unchecked Sendable {
    public static let maximumDimension = 128
    public let image: CGImage

    public init(catalogue: CompanionAssetCatalog) throws {
        try Task.checkCancellation()
        guard let frame = catalogue.defaultAsset.frames.first else {
            throw CompanionImageError.decodeFailed
        }
        let scale = min(1, Double(Self.maximumDimension) / Double(max(frame.width, frame.height)))
        let width = max(1, Int((Double(frame.width) * scale).rounded(.down)))
        let height = max(1, Int((Double(frame.height) * scale).rounded(.down)))
        guard let canvas = CGContext(data: nil, width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            throw CompanionImageError.decodeFailed
        }
        canvas.clear(CGRect(x: 0, y: 0, width: width, height: height))
        canvas.interpolationQuality = .high
        canvas.draw(frame, in: CGRect(x: 0, y: 0, width: width, height: height))
        try Task.checkCancellation()
        guard let image = canvas.makeImage() else { throw CompanionImageError.decodeFailed }
        self.image = image
    }
}

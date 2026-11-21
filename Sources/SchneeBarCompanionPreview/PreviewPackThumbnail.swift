import CoreGraphics
import Foundation
import SchneeBarCompanionAssets

/// Static representative artwork, never a separate animation or decoder.
enum PreviewPackThumbnail {
    static let side = 48
    static let maximumCount = CompanionOwnedPackStore.maximumInstalledPacks

    static func make(from catalogue: CompanionAssetCatalog) -> CGImage? {
        guard let frame = catalogue.defaultAsset.frames.first,
              let context = CGContext(data: nil, width: side, height: side,
                bitsPerComponent: 8, bytesPerRow: side * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            return nil
        }
        let scale = min(Double(side - 4) / Double(frame.width),
                        Double(side - 4) / Double(frame.height))
        let width = max(1, Double(frame.width) * scale)
        let height = max(1, Double(frame.height) * scale)
        context.clear(CGRect(x: 0, y: 0, width: side, height: side))
        context.interpolationQuality = .high
        context.draw(frame, in: CGRect(x: (Double(side) - width) / 2,
                                      y: (Double(side) - height) / 2,
                                      width: width, height: height))
        return context.makeImage()
    }
}

import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Converts one descriptor-read image into the existing v1 wire format.
/// No temporary source directories, caller-chosen manifest paths or bookmarks.
enum CompanionSingleImageCapture {
    static func capture(_ url: URL) throws -> CompanionAnimatedPackLoader.Capture {
        try Task.checkCancellation()
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        var bytes = try CompanionFileReader.read(url)
        var prepared = try CompanionImageDecoder.prepare(bytes)
        // A v1 singleImage is PNG. Preserve animated formats verbatim; for
        // static GIF/WebP normalize a bounded, fully decoded frame to PNG.
        if prepared.frameCount == 1, prepared.format != .png {
            let decoded = try CompanionImageDecoder.decodePrepared(prepared)
            guard let frame = decoded.frames.first else { throw CompanionImageError.decodeFailed }
            let encoded = NSMutableData()
            guard let destination = CGImageDestinationCreateWithData(
                encoded as CFMutableData, UTType.png.identifier as CFString, 1, nil
            ) else { throw CompanionImageError.decodeFailed }
            try Task.checkCancellation()
            CGImageDestinationAddImage(destination, frame, nil)
            guard CGImageDestinationFinalize(destination) else { throw CompanionImageError.decodeFailed }
            try Task.checkCancellation()
            guard encoded.length <= CompanionAnimatedPackLoader.maximumEncodedBytes else {
                throw CompanionAnimatedPackError.encodedBudget
            }
            bytes = encoded as Data
            prepared = try CompanionImageDecoder.prepare(bytes)
        }

        let kind: CompanionPackManifest.Kind
        let filename: String
        let clip: CompanionDecodedClip
        switch (prepared.format, prepared.frameCount) {
        case (.png, 1):
            kind = .singleImage
            filename = "run.png"
            clip = try CompanionStaticPackClip.make(prepared, kind: kind,
                pixelLimit: CompanionAnimatedPackLoader.maximumPixels).clip
        default:
            guard prepared.frameCount >= 2 else { throw CompanionAnimatedPackError.frameBudget }
            switch prepared.format {
            case .png: kind = .apng; filename = "run.png"
            case .gif: kind = .gif; filename = "run.gif"
            case .webp: kind = .webP; filename = "run.webp"
            }
            clip = try CompanionImageDecoder.decodePrepared(prepared)
        }
        let manifest = try CompanionPackManifest.decode(JSONSerialization.data(withJSONObject: [
            "formatVersion": 1, "name": "Imported image", "defaultState": "run",
            "clips": [["state": "run", "kind": kind.rawValue, "path": filename]]
        ]))
        let catalogue = try CompanionAssetCatalog(assets: [.run: clip], defaultState: .run)
        try Task.checkCancellation()
        return CompanionAnimatedPackLoader.Capture(manifest: manifest,
            clips: manifest.clips.map { ($0, [bytes]) }, catalogue: catalogue)
    }
}

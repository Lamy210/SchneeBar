import Foundation
import SchneeBarCompanionCore

public enum CompanionAnimatedPackError: Error, Equatable {
    case unsupportedKind, encodedBudget, frameBudget, pixelBudget
    case formatMismatch, invalidLimits
}

/// First pack decoding slice: GIF/APNG/WebP only. Static procedural images,
/// sprite sheets and directory sequences need their own bounded planners.
/// No copying, persistence, UI, or archive extraction.
public enum CompanionAnimatedPackLoader {
    public static let maximumEncodedBytes = 32 * 1024 * 1024
    public static let maximumFrames = 240
    public static let maximumPixels = CompanionImageDecoder.maximumTotalPixels

    struct Limits {
        var bytes = maximumEncodedBytes
        var frames = maximumFrames
        var pixels = maximumPixels
    }

    public static func load(_ url: URL) throws -> CompanionAssetCatalog {
        try load(url, limits: Limits())
    }

    /// Internal limits seam can only tighten the production ceilings.
    static func load(_ url: URL, limits: Limits) throws -> CompanionAssetCatalog {
        guard (1...maximumEncodedBytes).contains(limits.bytes),
              (1...maximumFrames).contains(limits.frames),
              (1...maximumPixels).contains(limits.pixels) else {
            throw CompanionAnimatedPackError.invalidLimits
        }
        try Task.checkCancellation()
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let directory = try CompanionPackDirectory(url)
        let manifest = try directory.manifest()
        // Fail unsupported mixed packs before any referenced clip is read.
        guard manifest.clips.allSatisfy({ expectedFormat($0.kind) != nil }) else {
            throw CompanionAnimatedPackError.unsupportedKind
        }

        var remainingBytes = limits.bytes
        var remainingFrames = limits.frames
        var remainingMetadataPixels = limits.pixels
        var prepared: [(CompanionState, CompanionImageDecoder.Prepared)] = []

        // Read once per declared clip, including aliases, retaining its source
        // for a second phase. ALL metadata must fit before explicit decoding.
        for entry in manifest.clips {
            try Task.checkCancellation()
            guard remainingBytes > 0 else { throw CompanionAnimatedPackError.encodedBudget }
            let data: Data
            do {
                data = try directory.read(entry.path, maximumBytes: remainingBytes)
            } catch CompanionFileReadError.invalidSize {
                throw CompanionAnimatedPackError.encodedBudget
            }
            remainingBytes -= data.count
            let candidate = try CompanionImageDecoder.prepare(data)
            guard candidate.format == expectedFormat(entry.kind) else {
                throw CompanionAnimatedPackError.formatMismatch
            }
            guard candidate.frameCount >= 2,
                  candidate.frameCount <= remainingFrames else {
                throw CompanionAnimatedPackError.frameBudget
            }
            guard candidate.metadataPixels <= remainingMetadataPixels else {
                throw CompanionAnimatedPackError.pixelBudget
            }
            remainingFrames -= candidate.frameCount
            remainingMetadataPixels -= candidate.metadataPixels
            prepared.append((entry.state, candidate))
        }

        var assets: [CompanionState: CompanionDecodedClip] = [:]
        var remainingDecodedPixels = limits.pixels
        for (state, candidate) in prepared {
            try Task.checkCancellation()
            let decoded = try CompanionImageDecoder.decodePrepared(candidate, pixelLimit: remainingDecodedPixels)
            // decodePrepared checks the remaining budget before normalizing
            // each frame; this second calculation tracks actual retained cost.
            for frame in decoded.frames { remainingDecodedPixels -= frame.width * frame.height }
            assets[state] = decoded
        }
        try Task.checkCancellation()
        return try CompanionAssetCatalog(assets: assets, defaultState: manifest.defaultState)
    }

    private static func expectedFormat(_ kind: CompanionPackManifest.Kind) -> CompanionImageDecoder.Format? {
        switch kind {
        case .gif: .gif
        case .apng: .png
        case .webP: .webp
        case .singleImage, .spriteSheet4x2, .pngSequence: nil
        }
    }
}

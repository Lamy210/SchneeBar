import Foundation
import SchneeBarCompanionCore

public enum CompanionAnimatedPackError: Error, Equatable {
    case unsupportedKind, encodedBudget, frameBudget, pixelBudget
    case formatMismatch, invalidLimits
}

/// Pack decoding for animated files and static PNG-derived clips.
/// Directory sequences require a separately bounded enumeration planner.
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
        var prepared: [(CompanionPackManifest.Clip, CompanionImageDecoder.Prepared)] = []

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
            let staticKind = isStatic(entry.kind)
            guard staticKind ? candidate.frameCount == 1 : candidate.frameCount >= 2
            else { throw CompanionAnimatedPackError.frameBudget }
            let frames = staticKind ? CompanionStaticPackClip.frameCount : candidate.frameCount
            let generatedPixels = staticKind
                ? try CompanionStaticPackClip.outputPixels(entry.kind, width: candidate.firstWidth,
                                                          height: candidate.firstHeight)
                : 0
            guard frames <= remainingFrames else { throw CompanionAnimatedPackError.frameBudget }
            guard candidate.metadataPixels <= remainingMetadataPixels,
                  generatedPixels <= remainingMetadataPixels - candidate.metadataPixels
            else { throw CompanionAnimatedPackError.pixelBudget }
            remainingFrames -= frames
            remainingMetadataPixels -= candidate.metadataPixels + generatedPixels
            prepared.append((entry, candidate))
        }

        var assets: [CompanionState: CompanionDecodedClip] = [:]
        var remainingDecodedPixels = limits.pixels
        for (entry, candidate) in prepared {
            try Task.checkCancellation()
            if isStatic(entry.kind) {
                let result = try CompanionStaticPackClip.make(candidate, kind: entry.kind,
                                                              pixelLimit: remainingDecodedPixels)
                remainingDecodedPixels -= result.chargedPixels
                assets[entry.state] = result.clip
            } else {
                let decoded = try CompanionImageDecoder.decodePrepared(candidate, pixelLimit: remainingDecodedPixels)
                for frame in decoded.frames { remainingDecodedPixels -= frame.width * frame.height }
                assets[entry.state] = decoded
            }
        }
        try Task.checkCancellation()
        return try CompanionAssetCatalog(assets: assets, defaultState: manifest.defaultState)
    }

    private static func isStatic(_ kind: CompanionPackManifest.Kind) -> Bool {
        switch kind {
        case .singleImage, .spriteSheet4x2: true
        default: false
        }
    }

    private static func expectedFormat(_ kind: CompanionPackManifest.Kind) -> CompanionImageDecoder.Format? {
        switch kind {
        case .gif: .gif
        case .apng: .png
        case .webP: .webp
        case .singleImage, .spriteSheet4x2: .png
        case .pngSequence: nil
        }
    }
}

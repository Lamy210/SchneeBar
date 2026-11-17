import CoreGraphics
import Foundation
import SchneeBarCompanionCore

public enum CompanionAnimatedPackError: Error, Equatable {
    case unsupportedKind, encodedBudget, frameBudget, pixelBudget
    case formatMismatch, invalidLimits, inconsistentFrameDimensions
}

/// Pack decoding for all six Runner v1 clip kinds, including bounded sequences.
/// No UI or archive extraction. Capture is internal to the owned-store worker.
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
        try capture(url, limits: limits).catalogue
    }

    /// Return exactly the admitted, successfully decoded bytes to the
    /// persistence worker. No public constructor or caller-supplied paths.
    struct Capture {
        let manifest: CompanionPackManifest
        let clips: [(CompanionPackManifest.Clip, [Data])]
        let catalogue: CompanionAssetCatalog
    }

    static func capture(_ url: URL, limits: Limits = Limits()) throws -> Capture {
        try Task.checkCancellation()
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        return try capture(CompanionPackDirectory(url), limits: limits)
    }

    static func capture(_ directory: CompanionPackDirectory, limits: Limits = Limits()) throws -> Capture {
        guard (1...maximumEncodedBytes).contains(limits.bytes),
              (1...maximumFrames).contains(limits.frames),
              (1...maximumPixels).contains(limits.pixels) else {
            throw CompanionAnimatedPackError.invalidLimits
        }
        try Task.checkCancellation()
        let manifest = try directory.manifest()
        var remainingBytes = limits.bytes
        var remainingFrames = limits.frames
        var remainingMetadataPixels = limits.pixels
        var prepared: [(CompanionPackManifest.Clip, [CompanionImageDecoder.Prepared])] = []
        var captured: [(CompanionPackManifest.Clip, [Data])] = []

        // Read once per declared clip, including aliases, retaining its source
        // for a second phase. ALL metadata must fit before explicit decoding.
        for entry in manifest.clips {
            try Task.checkCancellation()
            guard remainingBytes > 0 else { throw CompanionAnimatedPackError.encodedBudget }
            if entry.kind == .pngSequence {
                let data: [Data]
                do {
                    data = try directory.readPNGSequence(entry.path, maximumBytes: remainingBytes,
                        maximumFrames: min(CompanionImageDecoder.maximumFrames, remainingFrames))
                } catch CompanionFileReadError.invalidSize {
                    throw CompanionAnimatedPackError.encodedBudget
                }
                var sequence: [CompanionImageDecoder.Prepared] = []
                for bytes in data {
                    try Task.checkCancellation()
                    remainingBytes -= bytes.count
                    let candidate = try CompanionImageDecoder.prepare(bytes)
                    guard candidate.format == .png, candidate.frameCount == 1 else {
                        throw CompanionAnimatedPackError.formatMismatch
                    }
                    if let first = sequence.first,
                       first.firstWidth != candidate.firstWidth || first.firstHeight != candidate.firstHeight {
                        throw CompanionAnimatedPackError.inconsistentFrameDimensions
                    }
                    guard candidate.metadataPixels <= remainingMetadataPixels else {
                        throw CompanionAnimatedPackError.pixelBudget
                    }
                    remainingMetadataPixels -= candidate.metadataPixels
                    remainingFrames -= 1
                    sequence.append(candidate)
                }
                prepared.append((entry, sequence))
                captured.append((entry, data))
                continue
            }

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
            prepared.append((entry, [candidate]))
            captured.append((entry, [data]))
        }

        var assets: [CompanionState: CompanionDecodedClip] = [:]
        var remainingDecodedPixels = limits.pixels
        for (entry, candidates) in prepared {
            try Task.checkCancellation()
            guard let candidate = candidates.first else { throw CompanionAnimatedPackError.frameBudget }
            if entry.kind == .pngSequence {
                var frames: [CGImage] = []
                for source in candidates {
                    try Task.checkCancellation()
                    let decoded = try CompanionImageDecoder.decodePrepared(source, pixelLimit: remainingDecodedPixels)
                    guard let frame = decoded.frames.first, decoded.frames.count == 1,
                          frame.width == candidate.firstWidth, frame.height == candidate.firstHeight else {
                        throw CompanionAnimatedPackError.inconsistentFrameDimensions
                    }
                    remainingDecodedPixels -= frame.width * frame.height
                    frames.append(frame)
                }
                let clip = try CompanionClip(revision: UUID(),
                    durations: Array(repeating: 1.0 / 12.0, count: frames.count))
                assets[entry.state] = CompanionDecodedClip(clip: clip, frames: frames)
            } else if isStatic(entry.kind) {
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
        let catalogue = try CompanionAssetCatalog(assets: assets, defaultState: manifest.defaultState)
        return Capture(manifest: manifest, clips: captured, catalogue: catalogue)
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

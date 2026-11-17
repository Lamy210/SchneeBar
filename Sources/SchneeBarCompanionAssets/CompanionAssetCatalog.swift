import CoreGraphics
import Foundation
import SchneeBarCompanionCore

public enum CompanionAssetCatalogError: Error, Equatable {
    case missingDefault
    case pixelBudget
}

/// Bounds the retained decoded catalogue, counting aliased clips once.
/// This is not an import preflight or a process-wide allocation limit.
public struct CompanionAssetCatalog: Sendable {
    private let assets: [CompanionState: CompanionDecodedClip]
    private let fallback: CompanionDecodedClip

    public init(assets: [CompanionState: CompanionDecodedClip], defaultState: CompanionState) throws {
        guard let fallback = assets[defaultState] else {
            throw CompanionAssetCatalogError.missingDefault
        }
        var seen: Set<UUID> = []
        var pixels = 0
        for asset in assets.values where seen.insert(asset.clip.revision).inserted {
            for frame in asset.frames {
                let count = frame.width * frame.height // already decoder-validated
                guard count <= CompanionImageDecoder.maximumTotalPixels - pixels else {
                    throw CompanionAssetCatalogError.pixelBudget
                }
                pixels += count
            }
        }
        self.assets = assets
        self.fallback = fallback
    }

    public func asset(for state: CompanionState) -> CompanionDecodedClip {
        assets[state] ?? fallback
    }
}

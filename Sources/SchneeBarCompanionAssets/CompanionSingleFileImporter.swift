import Foundation

/// Connects the descriptor reader, bounded decoder and immutable catalogue.
/// No path selection, user preferences, persistence or rendering authority.
/// A host must retain exactly one queue per import surface and cancel it on
/// stop. Only replace the installed catalogue on a successful latest result.
public enum CompanionSingleFileImporter {
    @MainActor
    public static func makeQueue() -> CompanionImportQueue<URL, CompanionAssetCatalog> {
        CompanionImportQueue { url in
            let bytes = try CompanionFileReader.read(url)
            try Task.checkCancellation()
            let decoded = try CompanionImageDecoder.decode(bytes)
            let catalogue = try CompanionAssetCatalog(assets: [.run: decoded], defaultState: .run)
            try Task.checkCancellation()
            return catalogue
        }
    }
}

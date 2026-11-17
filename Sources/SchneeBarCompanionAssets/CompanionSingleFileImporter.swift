import Foundation

/// Connects the descriptor reader, bounded decoder and immutable catalogue.
/// No path selection, user preferences, persistence or rendering authority.
/// Any security-scoped access is balanced within the actual worker lifetime.
/// A host must retain exactly one queue per import surface and cancel it on
/// stop. Only replace the installed catalogue on a successful latest result.
public enum CompanionSingleFileImporter {
    @MainActor
    public static func makeQueue() -> CompanionImportQueue<URL, CompanionAssetCatalog> {
        CompanionImportQueue { url in
            try Task.checkCancellation()
            // Non-sandboxed callers may have ordinary file access even if
            // starting a security scope returns false. The descriptor read
            // remains the authority; never persist a security-scoped bookmark.
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            let bytes = try CompanionFileReader.read(url)
            try Task.checkCancellation()
            let decoded = try CompanionImageDecoder.decode(bytes)
            let catalogue = try CompanionAssetCatalog(assets: [.run: decoded], defaultState: .run)
            try Task.checkCancellation()
            return catalogue
        }
    }
}

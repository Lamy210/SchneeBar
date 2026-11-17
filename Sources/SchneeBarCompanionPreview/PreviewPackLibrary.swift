import Darwin
import Foundation
import SchneeBarCompanionAssets

/// Only the explicit developer preview uses this separate store.
enum PreviewPackLibrary {
    enum Request: Sendable {
        case refresh, restoreSelection, install(URL), select(UUID), builtIn
        case trash(UUID), restoreTrash(UUID), purgeTrash(UUID), discardStage(UUID), discardPendingSelection
    }
    struct Output: Sendable {
        let inventory: CompanionOwnedPackStore.Inventory?
        let selection: CompanionOwnedPackStore.Selection?
        let message: String
    }

    static func defaultRoot() -> URL? {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first?.appendingPathComponent("dev.lamy.schneebar.companion-preview-packs-v1", isDirectory: true)
    }

    static func perform(_ request: Request, root: URL) throws -> Output {
        guard root.isFileURL, root.path.hasPrefix("/"),
              root.host == nil || root.host == "" || root.host == "localhost" else {
            throw CompanionOwnedPackError.unsafeRoot
        }
        let created = root.withUnsafeFileSystemRepresentation { path -> Int32 in
            guard let path else { return -1 }
            return mkdir(path, 0o700)
        }
        guard created == 0 || errno == EEXIST else { throw CompanionOwnedPackError.createFailed }
        // Existing paths are never chmodded. Each store call verifies root.
        let selection: CompanionOwnedPackStore.Selection?
        let message: String
        switch request {
        case .refresh:
            selection = nil
            message = "Library refreshed."
        case .restoreSelection:
            let restored = try CompanionOwnedPackStore.restoreSelection(in: root)
            selection = restored
            if case .unavailable = restored {
                message = "Saved pack unavailable. Default restored."
            } else {
                message = "Saved choice restored."
            }
        case .install(let source):
            _ = try CompanionOwnedPackStore.install(from: source, into: root)
            selection = nil
            message = "Pack saved. Select it to use it."
        case .select(let id):
            selection = try CompanionOwnedPackStore.select(id: id, in: root)
            message = "Pack selected and saved."
        case .builtIn:
            try CompanionOwnedPackStore.selectBuiltIn(in: root)
            selection = .builtIn
            message = "Default choice saved."
        case .trash(let id):
            try CompanionOwnedPackStore.trash(id: id, in: root)
            selection = nil
            message = "Pack moved to trash. Restore it before selecting again."
        case .restoreTrash(let id):
            try CompanionOwnedPackStore.restore(id: id, in: root)
            selection = nil
            message = "Pack restored without selecting it."
        case .purgeTrash(let id):
            try CompanionOwnedPackStore.purgeTrash(id: id, in: root)
            selection = nil
            message = "Trash entry permanently removed."
        case .discardStage(let id):
            try CompanionOwnedPackStore.discardAbandonedStage(id: id, in: root)
            selection = nil
            message = "Abandoned import removed."
        case .discardPendingSelection:
            try CompanionOwnedPackStore.discardPendingSelection(in: root)
            selection = nil
            message = "Uncommitted selection discarded."
        }
        // Failure to list after a durable commit does not undo the commit.
        let inventory = try? CompanionOwnedPackStore.inventory(in: root)
        return Output(inventory: inventory, selection: selection,
                      message: inventory == nil ? message + " Library listing unavailable." : message)
    }
}

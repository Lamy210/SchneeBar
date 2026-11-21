import Darwin
import Foundation

extension CompanionOwnedPackStore {
    static let selectionName = ".selection-v1"
    static let selectionStageName = ".selection-pending"
    private static let selectionByteCount = 40 // "v1\n" + 36-byte UUID + "\n"

    public enum Selection: Sendable {
        case builtIn
        case installed(id: UUID, catalogue: CompanionAssetCatalog)
        /// The saved package was missing or failed complete validation.
        /// The stale preference was cleared before returning this result.
        case unavailable(id: UUID)
    }

    /// An observation only. Unlike restoreSelection, this operation never
    /// clears or repairs an unavailable saved choice.
    public enum ReadOnlySelection: Sendable {
        case builtIn
        case installed(id: UUID, catalogue: CompanionAssetCatalog)
        case unavailable(id: UUID)
    }

    /// Read and validate the committed choice under a single shared root
    /// lock. Use in a cancellable host acquisition worker. Malformed or
    /// unsafe selection records and root/lock errors propagate; they are
    /// not interpreted as built-in and are never modified.
    public static func readSelection(in privateRoot: URL) throws -> ReadOnlySelection {
        try Task.checkCancellation()
        let root = try openRoot(privateRoot)
        defer { _ = Darwin.close(root) }
        try lockRoot(root, exclusive: false)
        guard let id = try selectedID(root) else {
            try Task.checkCancellation()
            return .builtIn
        }
        let catalogue: CompanionAssetCatalog
        do {
            catalogue = try CompanionAnimatedPackLoader.capture(openPack(id, root: root)).catalogue
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            try Task.checkCancellation()
            return .unavailable(id: id)
        }
        try Task.checkCancellation()
        return .installed(id: id, catalogue: catalogue)
    }

    /// Explicit select: validate the whole catalogue before changing the
    /// preference. A rejected candidate leaves the previous choice intact.
    public static func select(id: UUID, in privateRoot: URL) throws -> Selection {
        try select(id: id, in: privateRoot, beforePublish: {})
    }

    static func select(id: UUID, in privateRoot: URL,
                       beforePublish: () throws -> Void) throws -> Selection {
        let root = try openRoot(privateRoot)
        defer { _ = Darwin.close(root) }
        try lockRoot(root, exclusive: true)
        let catalogue = try CompanionAnimatedPackLoader.capture(openPack(id, root: root)).catalogue
        try saveSelection(id, root: root, beforePublish: beforePublish)
        return .installed(id: id, catalogue: catalogue)
    }

    /// Startup is an explicit caller action, not an automatic task. No
    /// source URL, event opt-in, CPU preference or Runner data is restored.
    public static func restoreSelection(in privateRoot: URL) throws -> Selection {
        try Task.checkCancellation()
        let root = try openRoot(privateRoot)
        defer { _ = Darwin.close(root) }
        try lockRoot(root, exclusive: true)
        guard let id = try selectedID(root) else { return .builtIn }
        let catalogue: CompanionAssetCatalog
        do {
            catalogue = try CompanionAnimatedPackLoader.capture(openPack(id, root: root)).catalogue
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            // Under exclusive lock, all cooperating store operations have
            // stopped. Do not leave an invalid choice that resurrects later.
            try Task.checkCancellation()
            try clearSelection(root)
            return .unavailable(id: id)
        }
        try Task.checkCancellation()
        return .installed(id: id, catalogue: catalogue)
    }

    /// Explicitly switch to the built-in artwork (absence of preference).
    /// Also permits resetting malformed content in a safe private file,
    /// but will never follow or unlink a symlink or special file.
    public static func selectBuiltIn(in privateRoot: URL) throws {
        let root = try openRoot(privateRoot)
        defer { _ = Darwin.close(root) }
        try lockRoot(root, exclusive: true)
        try Task.checkCancellation()
        try clearSelection(root)
    }

    /// Explicit crash-recovery operation. A pending write is never replayed
    /// because it might not have reached the selection commit point.
    public static func discardPendingSelection(in privateRoot: URL) throws {
        let root = try openRoot(privateRoot)
        defer { _ = Darwin.close(root) }
        try lockRoot(root, exclusive: true)
        try Task.checkCancellation()
        try removeSelectionFile(root, name: selectionStageName)
    }

    /// Read exactly one versioned UUID record. Do not coerce malformed
    /// content, and do not follow a symbolic link. Absence means built-in.
    static func selectedID(_ root: Int32) throws -> UUID? {
        guard let expected = try selectionFileInfo(root, name: selectionName) else { return nil }
        let fd = selectionName.withCString {
            Darwin.openat(root, $0, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        }
        guard fd >= 0 else { throw CompanionOwnedPackError.invalidSelection }
        defer { _ = Darwin.close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, sameIdentity(info, expected),
              info.st_size == selectionByteCount else { throw CompanionOwnedPackError.invalidSelection }
        let bytes = try CompanionFileReader.readOpenedFile(fd, limit: selectionByteCount, requireSingleLink: true)
        guard bytes.count == selectionByteCount, let value = String(data: bytes, encoding: .utf8),
              value.hasPrefix("v1\n"), value.hasSuffix("\n"),
              let id = UUID(uuidString: String(value.dropFirst(3).dropLast())),
              value == serialized(id) else { throw CompanionOwnedPackError.invalidSelection }
        return id
    }

    /// No-follow metadata lookup, including root device and ownership.
    /// Absence is distinct from an unsafe or inaccessible record.
    static func selectionFileInfo(_ root: Int32, name: String) throws -> stat? {
        var info = stat()
        let status = name.withCString { fstatat(root, $0, &info, AT_SYMLINK_NOFOLLOW) }
        if status != 0 {
            if errno == ENOENT { return nil }
            throw CompanionOwnedPackError.invalidSelection
        }
        var rootInfo = stat()
        guard fstat(root, &rootInfo) == 0,
              (info.st_mode & mode_t(S_IFMT)) == mode_t(S_IFREG),
              info.st_uid == geteuid(), info.st_dev == rootInfo.st_dev,
              info.st_nlink == 1, (info.st_mode & mode_t(0o077)) == 0
        else { throw CompanionOwnedPackError.invalidSelection }
        return info
    }

    private static func serialized(_ id: UUID) -> String {
        "v1\n" + id.uuidString.lowercased() + "\n"
    }

    private static func sameIdentity(_ a: stat, _ b: stat) -> Bool {
        a.st_dev == b.st_dev && a.st_ino == b.st_ino && a.st_uid == b.st_uid &&
            a.st_mode == b.st_mode && a.st_nlink == b.st_nlink
    }

    private static func saveSelection(_ id: UUID, root: Int32,
                                      beforePublish: () throws -> Void) throws {
        try Task.checkCancellation()
        let previous = try selectionFileInfo(root, name: selectionName)
        guard try selectionFileInfo(root, name: selectionStageName) == nil else {
            throw CompanionOwnedPackError.recoveryRequired
        }
        var created = false
        do {
            try createFile(parent: root, name: selectionStageName, data: Data(serialized(id).utf8)) {
                created = true
            }
            guard let pending = try selectionFileInfo(root, name: selectionStageName)
            else { throw CompanionOwnedPackError.selectionWriteFailed }
            try beforePublish()
            try Task.checkCancellation()
            guard let currentPending = try selectionFileInfo(root, name: selectionStageName),
                  sameIdentity(pending, currentPending) else { throw CompanionOwnedPackError.selectionWriteFailed }
            let current = try selectionFileInfo(root, name: selectionName)
            switch (previous, current) {
            case (nil, nil): break
            case let (a?, b?) where sameIdentity(a, b): break
            default: throw CompanionOwnedPackError.selectionWriteFailed
            }
            // Private exclusive root is the trust boundary. Same-user
            // noncooperating writes between checks and rename are not solved.
            let result = selectionStageName.withCString { src in
                selectionName.withCString { dst in
                    if previous == nil { return renameatx_np(root, src, root, dst, UInt32(RENAME_EXCL)) }
                    return renameat(root, src, root, dst)
                }
            }
            guard result == 0 else { throw CompanionOwnedPackError.selectionWriteFailed }
        } catch {
            if created {
                do { try removeSelectionFile(root, name: selectionStageName) }
                catch { throw CompanionOwnedPackError.cleanupFailed }
            }
            throw error
        }
    }

    static func clearSelection(_ root: Int32) throws {
        try removeSelectionFile(root, name: selectionName)
    }

    private static func removeSelectionFile(_ root: Int32, name: String) throws {
        guard let before = try selectionFileInfo(root, name: name) else { return }
        guard let after = try selectionFileInfo(root, name: name), sameIdentity(before, after)
        else { throw CompanionOwnedPackError.invalidSelection }
        guard name.withCString({ unlinkat(root, $0, 0) }) == 0
        else { throw CompanionOwnedPackError.selectionWriteFailed }
    }
}

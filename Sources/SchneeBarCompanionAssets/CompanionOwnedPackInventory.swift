import Darwin
import Foundation

extension CompanionOwnedPackStore {
    /// Conservative slot reservation, NOT an exact filesystem byte quota.
    public static let maximumInstalledPacks = 16
    public static let maximumReservedEncodedBytes = maximumInstalledPacks *
        (CompanionAnimatedPackLoader.maximumEncodedBytes + CompanionPackManifest.maximumBytes)

    public struct Entry: Sendable, Equatable, Identifiable {
        public let id: UUID
        /// nil means the directory or manifest could not be safely read.
        /// A valid manifest does not establish image decode validity.
        public let name: String?
        public let clipCount: Int?
    }

    public struct Inventory: Sendable {
        public let entries: [Entry]
        public let abandonedStageIDs: [UUID]
        public let trashedIDs: [UUID]
        public var abandonedStageCount: Int { abandonedStageIDs.count }
        public let pendingSelectionRecovery: Bool
        public let unknownEntryCount: Int
        public var canInstall: Bool {
            abandonedStageCount == 0 && !pendingSelectionRecovery && unknownEntryCount == 0 &&
                entries.count + trashedIDs.count < CompanionOwnedPackStore.maximumInstalledPacks
        }
    }

    /// Metadata only. Never decode images or expose source paths for listing.
    public static func inventory(in privateRoot: URL) throws -> Inventory {
        let root = try openRoot(privateRoot)
        defer { _ = Darwin.close(root) }
        try lockRoot(root, exclusive: false)
        let snapshot = try scan(root)
        var entries: [Entry] = []
        for id in snapshot.ids {
            try Task.checkCancellation()
            do {
                let manifest = try openPack(id, root: root).manifest()
                entries.append(Entry(id: id, name: manifest.name, clipCount: manifest.clips.count))
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                entries.append(Entry(id: id, name: nil, clipCount: nil))
            }
        }
        return Inventory(entries: entries, abandonedStageIDs: snapshot.staged,
                         trashedIDs: snapshot.trashed, pendingSelectionRecovery: snapshot.pendingSelection,
                         unknownEntryCount: snapshot.unknown)
    }

    /// Selection accepts only a UUID and revalidates all encoded content.
    /// Pin the selected directory relative to the current private root.
    public static func load(id: UUID, from privateRoot: URL) throws -> CompanionAssetCatalog {
        let root = try openRoot(privateRoot)
        defer { _ = Darwin.close(root) }
        try lockRoot(root, exclusive: false)
        return try CompanionAnimatedPackLoader.capture(openPack(id, root: root)).catalogue
    }

    // Advisory lock on the root directory descriptor, no persistent lock
    // file or stale lock token. All cooperating store operations use it.
    // The private local filesystem must support flock; fail closed otherwise.
    static func lockRoot(_ fd: Int32, exclusive: Bool) throws {
        guard flock(fd, (exclusive ? LOCK_EX : LOCK_SH) | LOCK_NB) == 0 else {
            throw CompanionOwnedPackError.busy
        }
    }

    struct Scan {
        var ids: [UUID] = []
        var staged: [UUID] = []
        var trashed: [UUID] = []
        var pendingSelection = false
        var unknown = 0
    }

    /// Maximum 128 raw entries, including hidden entries and dot entries.
    /// Unknowns and stage remnants are reported, never implicitly deleted.
    static func scan(_ root: Int32) throws -> Scan {
        var result = Scan()
        for candidate in try listNames(root, maximum: 128) {
            guard let name = candidate else { result.unknown += 1; continue }
            if name == selectionName {
                // The fixed preference file is not a package slot. Unsafe
                // file types are counted as unknown; never follow a link.
                do { _ = try selectionFileInfo(root, name: name) }
                catch { result.unknown += 1 }
            } else if name == selectionStageName {
                // Only a safe private pending record is eligible for explicit recovery.
                do {
                    if try selectionFileInfo(root, name: name) != nil { result.pendingSelection = true }
                    else { result.unknown += 1 }
                } catch { result.unknown += 1 }
            } else if name.hasSuffix(".schneerunner"),
               let id = UUID(uuidString: String(name.dropLast(".schneerunner".count))),
               name == packName(id) {
                result.ids.append(id)
            } else if name.hasPrefix(".stage-"),
                      let id = UUID(uuidString: String(name.dropFirst(".stage-".count))),
                      name == stageName(id) {
                result.staged.append(id)
            } else if name.hasPrefix(".trash-"),
                      let id = UUID(uuidString: String(name.dropFirst(".trash-".count))),
                      name == trashName(id) {
                result.trashed.append(id)
            } else {
                result.unknown += 1
            }
        }
        result.ids.sort { $0.uuidString < $1.uuidString }
        result.staged.sort { $0.uuidString < $1.uuidString }
        result.trashed.sort { $0.uuidString < $1.uuidString }
        return result
    }

    /// Include dot entries in the scan cap, never silently discard malformed
    /// names. A nil entry means a name could not be represented as UTF-8.
    static func listNames(_ root: Int32, maximum: Int) throws -> [String?] {
        let listing = Darwin.openat(root, ".", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard listing >= 0 else { throw CompanionOwnedPackError.unsafeRoot }
        guard let stream = fdopendir(listing) else {
            _ = Darwin.close(listing)
            throw CompanionOwnedPackError.unsafeRoot
        }
        defer { _ = closedir(stream) }
        var result: [String?] = []
        var count = 0
        while true {
            try Task.checkCancellation()
            errno = 0
            guard let item = readdir(stream) else {
                guard errno == 0 else { throw CompanionOwnedPackError.unsafeRoot }
                break
            }
            count += 1
            guard count <= maximum else { throw CompanionOwnedPackError.inventoryLimit }
            let length = Int(item.pointee.d_namlen)
            let name: String? = withUnsafeBytes(of: &item.pointee.d_name) { raw in
                guard length > 0, length <= 255, length < raw.count,
                      raw[length] == 0, !raw.prefix(length).contains(0) else { return nil }
                return String(bytes: raw.prefix(length), encoding: .utf8)
            }
            if name == "." || name == ".." { continue }
            result.append(name)
        }
        return result
    }

    static func packName(_ id: UUID) -> String {
        id.uuidString.lowercased() + ".schneerunner"
    }

    static func stageName(_ id: UUID) -> String { ".stage-" + id.uuidString.lowercased() }
    static func trashName(_ id: UUID) -> String { ".trash-" + id.uuidString.lowercased() }

    static func openPack(_ id: UUID, root: Int32) throws -> CompanionPackDirectory {
        try CompanionPackDirectory(ownedDescriptor: openPrivateChild(packName(id), root: root))
    }

    static func openPrivateChild(_ name: String, root: Int32) throws -> Int32 {
        let fd = name.withCString {
            Darwin.openat(root, $0, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
        }
        guard fd >= 0 else { throw CompanionOwnedPackError.missingPack }
        var info = stat()
        var rootInfo = stat()
        guard fstat(fd, &info) == 0, fstat(root, &rootInfo) == 0,
              privateDirectory(info), info.st_dev == rootInfo.st_dev else {
            _ = Darwin.close(fd)
            throw CompanionOwnedPackError.unsafeRoot
        }
        return fd
    }
}

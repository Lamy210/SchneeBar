import Darwin
import Foundation
import SchneeBarCompanionCore

public enum CompanionOwnedPackError: Error, Equatable {
    case unsafeRoot, createFailed, writeFailed, publishFailed, cleanupFailed
    case busy, inventoryLimit, recoveryRequired, packLimit, missingPack
    case unsafeCleanup, moveFailed
    case invalidSelection, selectionWriteFailed
}

/// A single import transaction. Caller supplies an existing app-owned,
/// private local directory, not a user-selected destination or Runner store.
/// No UI, deletion, migration, or background work is started here.
public enum CompanionOwnedPackStore {
    public struct Installed: Sendable {
        public let id: UUID
        public let catalogue: CompanionAssetCatalog
    }

    public static func install(from source: URL, into privateRoot: URL) throws -> Installed {
        try install(from: source, into: privateRoot, beforePublish: {})
    }

    // Internal fault injection seam, invoked only before the commit point.
    static func install(from source: URL, into privateRoot: URL,
                        maximumPacks: Int = maximumInstalledPacks,
                        beforePublish: () throws -> Void) throws -> Installed {
        try Task.checkCancellation()
        guard (1...maximumInstalledPacks).contains(maximumPacks) else {
            throw CompanionOwnedPackError.packLimit
        }
        let root = try openRoot(privateRoot)
        defer { _ = Darwin.close(root) }
        try lockRoot(root, exclusive: true)
        let inventory = try scan(root)
        guard inventory.staged.isEmpty, inventory.unknown == 0 else {
            throw CompanionOwnedPackError.recoveryRequired
        }
        guard inventory.ids.count + inventory.trashed.count < maximumPacks else { throw CompanionOwnedPackError.packLimit }
        let capture = try CompanionAnimatedPackLoader.capture(source)
        let id = UUID()
        let final = packName(id)
        let staging = stageName(UUID())
        guard staging.withCString({ mkdirat(root, $0, 0o700) }) == 0 else {
            throw CompanionOwnedPackError.createFailed
        }
        let fd = staging.withCString {
            Darwin.openat(root, $0, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        }
        guard fd >= 0 else {
            _ = staging.withCString { unlinkat(root, $0, AT_REMOVEDIR) }
            throw CompanionOwnedPackError.createFailed
        }
        defer { _ = Darwin.close(fd) }
        var stageInfo = stat()
        guard fstat(fd, &stageInfo) == 0, privateDirectory(stageInfo) else {
            throw CompanionOwnedPackError.unsafeRoot
        }
        // All names are generated internally. Keep explicit cleanup records;
        // never recursively follow or remove arbitrary directory contents.
        var flatFiles: [String] = []
        var subdirectories: [(name: String, fd: Int32, files: [String])] = []
        defer { for sub in subdirectories { _ = Darwin.close(sub.fd) } }
        do {
            var entries: [[String: String]] = []
            for (entry, data) in capture.clips {
                try Task.checkCancellation()
                let state = stateName(entry.state)
                let path: String
                if entry.kind == .pngSequence {
                    path = state
                    guard path.withCString({ mkdirat(fd, $0, 0o700) }) == 0 else {
                        throw CompanionOwnedPackError.createFailed
                    }
                    let sub = path.withCString {
                        Darwin.openat(fd, $0, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                    }
                    guard sub >= 0 else {
                        _ = path.withCString { unlinkat(fd, $0, AT_REMOVEDIR) }
                        throw CompanionOwnedPackError.createFailed
                    }
                    subdirectories.append((path, sub, []))
                    var info = stat()
                    guard fstat(sub, &info) == 0, privateDirectory(info),
                          info.st_dev == stageInfo.st_dev else { throw CompanionOwnedPackError.unsafeRoot }
                    for (index, bytes) in data.enumerated() {
                        let name = String(format: "frame-%03d.png", index)
                        try createFile(parent: sub, name: name, data: bytes) {
                            subdirectories[subdirectories.count - 1].files.append(name)
                        }
                    }
                } else {
                    let suffix: String
                    switch entry.kind {
                    case .gif: suffix = ".gif"
                    case .webP: suffix = ".webp"
                    default: suffix = ".png"
                    }
                    path = state + suffix
                    guard data.count == 1, let bytes = data.first else {
                        throw CompanionOwnedPackError.writeFailed
                    }
                    try createFile(parent: fd, name: path, data: bytes) { flatFiles.append(path) }
                }
                entries.append(["state": state, "kind": entry.kind.rawValue, "path": path])
            }
            let manifest = try JSONSerialization.data(withJSONObject: [
                "formatVersion": 1, "name": capture.manifest.name,
                "defaultState": stateName(capture.manifest.defaultState), "clips": entries
            ], options: [.sortedKeys])
            _ = try CompanionPackManifest.decode(manifest)
            try createFile(parent: fd, name: CompanionPackManifest.filename, data: manifest) {
                flatFiles.append(CompanionPackManifest.filename)
            }
            try beforePublish()
            try Task.checkCancellation()
            // Confirm the stage still names the directory we opened.
            var linked = stat()
            guard staging.withCString({ fstatat(root, $0, &linked, AT_SYMLINK_NOFOLLOW) }) == 0,
                  linked.st_dev == stageInfo.st_dev, linked.st_ino == stageInfo.st_ino,
                  privateDirectory(linked) else { throw CompanionOwnedPackError.unsafeRoot }
            // Single same-directory rename, no overwrite. Cancellation
            // after this point cannot roll back a successfully committed pack.
            guard staging.withCString({ src in
                final.withCString { dst in
                    renameatx_np(root, src, root, dst, UInt32(RENAME_EXCL))
                }
            }) == 0 else { throw CompanionOwnedPackError.publishFailed }
            return Installed(id: id, catalogue: capture.catalogue)
        } catch {
            var cleaned = true
            for sub in subdirectories {
                for name in sub.files {
                    if name.withCString({ unlinkat(sub.fd, $0, 0) }) != 0 { cleaned = false }
                }
                if sub.name.withCString({ unlinkat(fd, $0, AT_REMOVEDIR) }) != 0 { cleaned = false }
            }
            for name in flatFiles {
                if name.withCString({ unlinkat(fd, $0, 0) }) != 0 { cleaned = false }
            }
            var linked = stat()
            if staging.withCString({ fstatat(root, $0, &linked, AT_SYMLINK_NOFOLLOW) }) != 0
                || linked.st_dev != stageInfo.st_dev || linked.st_ino != stageInfo.st_ino {
                cleaned = false
            } else if staging.withCString({ unlinkat(root, $0, AT_REMOVEDIR) }) != 0 {
                cleaned = false
            }
            if !cleaned { throw CompanionOwnedPackError.cleanupFailed }
            throw error
        }
    }

    static func openRoot(_ url: URL) throws -> Int32 {
        guard url.isFileURL, url.path.hasPrefix("/"),
              url.host == nil || url.host == "" || url.host == "localhost" else {
            throw CompanionOwnedPackError.unsafeRoot
        }
        let fd = url.withUnsafeFileSystemRepresentation {
            guard let path = $0 else { return Int32(-1) }
            return Darwin.open(path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        }
        guard fd >= 0 else { throw CompanionOwnedPackError.unsafeRoot }
        var info = stat()
        guard fstat(fd, &info) == 0, privateDirectory(info) else {
            _ = Darwin.close(fd)
            throw CompanionOwnedPackError.unsafeRoot
        }
        return fd
    }

    static func privateDirectory(_ info: stat) -> Bool {
        (info.st_mode & mode_t(S_IFMT)) == mode_t(S_IFDIR)
            && info.st_uid == geteuid()
            && (info.st_mode & mode_t(0o077)) == 0
    }

    static func createFile(parent: Int32, name: String, data: Data,
                                   created: () -> Void) throws {
        try Task.checkCancellation()
        let fd = name.withCString {
            Darwin.openat(parent, $0, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, mode_t(0o600))
        }
        guard fd >= 0 else { throw CompanionOwnedPackError.createFailed }
        created()
        defer { _ = Darwin.close(fd) }
        try data.withUnsafeBytes { (buffer: UnsafeRawBufferPointer) in
            guard let base = buffer.baseAddress else { throw CompanionOwnedPackError.writeFailed }
            var offset = 0
            while offset < buffer.count {
                try Task.checkCancellation()
                let count = Darwin.write(fd, base.advanced(by: offset), min(64 * 1024, buffer.count - offset))
                if count < 0, errno == EINTR { continue }
                guard count > 0 else { throw CompanionOwnedPackError.writeFailed }
                offset += count
            }
        }
        guard fsync(fd) == 0 else { throw CompanionOwnedPackError.writeFailed }
    }

    private static func stateName(_ state: CompanionState) -> String {
        switch state {
        case .idle: "idle"
        case .walk: "walk"
        case .run: "run"
        case .dash: "dash"
        case .sprint: "sprint"
        }
    }
}

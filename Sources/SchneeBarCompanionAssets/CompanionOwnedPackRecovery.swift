import Darwin
import Foundation

extension CompanionOwnedPackStore {
    /// Move to a reversible tombstone under the same private root. Retains
    /// the slot reservation until explicit purge. No image bytes modified.
    public static func trash(id: UUID, in privateRoot: URL) throws {
        try move(packName(id), to: trashName(id), in: privateRoot, deselecting: id)
    }

    public static func restore(id: UUID, in privateRoot: URL) throws {
        try move(trashName(id), to: packName(id), in: privateRoot)
    }

    /// Irreversible, explicit operation, never performed by listing/startup.
    /// A failed partial cleanup keeps the tombstone for a later retry.
    public static func purgeTrash(id: UUID, in privateRoot: URL) throws {
        try purge(trashName(id), in: privateRoot)
    }

    /// After explicit confirmation, reclaim an abandoned import stage.
    /// Exclusive root lock excludes any cooperating live import.
    public static func discardAbandonedStage(id: UUID, in privateRoot: URL) throws {
        try purge(stageName(id), in: privateRoot)
    }

    private static func move(_ source: String, to destination: String, in url: URL,
                             deselecting id: UUID? = nil) throws {
        try Task.checkCancellation()
        let root = try openRoot(url)
        defer { _ = Darwin.close(root) }
        try lockRoot(root, exclusive: true)
        let fd = try openPrivateChild(source, root: root)
        defer { _ = Darwin.close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0 else { throw CompanionOwnedPackError.unsafeCleanup }
        try Task.checkCancellation()
        try requireIdentity(parent: root, name: source, expected: info)
        // Clear the persistent selection BEFORE moving the selected pack.
        // If rename subsequently fails, built-in is still the safe choice.
        if let id, try selectedID(root) == id {
            try clearSelection(root)
        }
        guard source.withCString({ src in
            destination.withCString { dst in
                renameatx_np(root, src, root, dst, UInt32(RENAME_EXCL))
            }
        }) == 0 else { throw CompanionOwnedPackError.moveFailed }
    }

    private struct Leaf {
        let name: String
        let info: stat
    }

    private struct SequenceDirectory {
        let name: String
        let fd: Int32
        let info: stat
        var files: [Leaf]
    }

    /// Before *any* unlink, validate the entire bounded, canonical generated
    /// layout. A partial stage may contain incomplete/empty regular files or
    /// missing entries; no arbitrary descendants, links, or unknown names.
    private static func purge(_ name: String, in url: URL) throws {
        try Task.checkCancellation()
        let root = try openRoot(url)
        defer { _ = Darwin.close(root) }
        try lockRoot(root, exclusive: true)
        let fd = try openPrivateChild(name, root: root)
        defer { _ = Darwin.close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0 else { throw CompanionOwnedPackError.unsafeCleanup }
        let states = ["idle", "walk", "run", "dash", "sprint"]
        let flatNames = Set(states.flatMap { state in [state + ".png", state + ".gif", state + ".webp"] })
        var files: [Leaf] = []
        var directories: [SequenceDirectory] = []
        defer { for directory in directories { _ = Darwin.close(directory.fd) } }
        var usedStates = Set<String>()
        var totalFrames = 0
        for value in try listNames(fd, maximum: 8) {
            guard let child = value else { throw CompanionOwnedPackError.unsafeCleanup }
            if child == CompanionPackManifest.filename {
                files.append(try inspectFile(child, parent: fd, device: info.st_dev))
                continue
            }
            if flatNames.contains(child) {
                let state = String(child.split(separator: ".")[0])
                guard usedStates.insert(state).inserted else { throw CompanionOwnedPackError.unsafeCleanup }
                files.append(try inspectFile(child, parent: fd, device: info.st_dev))
                continue
            }
            guard states.contains(child), usedStates.insert(child).inserted
            else { throw CompanionOwnedPackError.unsafeCleanup }
            let sub = try openPrivateChild(child, root: fd)
            var subInfo = stat()
            guard fstat(sub, &subInfo) == 0 else {
                _ = Darwin.close(sub)
                throw CompanionOwnedPackError.unsafeCleanup
            }
            directories.append(SequenceDirectory(name: child, fd: sub, info: subInfo, files: []))
            for value in try listNames(sub, maximum: 122) {
                guard let frame = value, frame.hasPrefix("frame-"), frame.hasSuffix(".png"),
                      let number = Int(frame.dropFirst(6).dropLast(4)),
                      (0..<120).contains(number),
                      frame == String(format: "frame-%03d.png", number),
                      totalFrames < 240 else { throw CompanionOwnedPackError.unsafeCleanup }
                directories[directories.count - 1].files.append(
                    try inspectFile(frame, parent: sub, device: info.st_dev))
                totalFrames += 1
            }
        }
        // Preflight is complete. Recheck identities before each unlink.
        // Cancellation before destructive work leaves everything intact;
        // after it begins, finish the bounded operation or report failure.
        try Task.checkCancellation()
        try requireIdentity(parent: root, name: name, expected: info)
        for directory in directories {
            try requireIdentity(parent: fd, name: directory.name, expected: directory.info)
            for file in directory.files {
                try removeFile(file, parent: directory.fd)
            }
            try requireIdentity(parent: fd, name: directory.name, expected: directory.info)
            guard directory.name.withCString({ unlinkat(fd, $0, AT_REMOVEDIR) }) == 0
            else { throw CompanionOwnedPackError.cleanupFailed }
        }
        for file in files { try removeFile(file, parent: fd) }
        try requireIdentity(parent: root, name: name, expected: info)
        guard name.withCString({ unlinkat(root, $0, AT_REMOVEDIR) }) == 0
        else { throw CompanionOwnedPackError.cleanupFailed }
    }

    private static func inspectFile(_ name: String, parent: Int32, device: dev_t) throws -> Leaf {
        var info = stat()
        guard name.withCString({ fstatat(parent, $0, &info, AT_SYMLINK_NOFOLLOW) }) == 0,
              (info.st_mode & mode_t(S_IFMT)) == mode_t(S_IFREG),
              info.st_dev == device, info.st_uid == geteuid(),
              info.st_nlink == 1, (info.st_mode & mode_t(0o077)) == 0
        else { throw CompanionOwnedPackError.unsafeCleanup }
        return Leaf(name: name, info: info)
    }

    private static func requireIdentity(parent: Int32, name: String, expected: stat) throws {
        var found = stat()
        guard name.withCString({ fstatat(parent, $0, &found, AT_SYMLINK_NOFOLLOW) }) == 0,
              found.st_dev == expected.st_dev, found.st_ino == expected.st_ino,
              found.st_mode == expected.st_mode, found.st_uid == expected.st_uid,
              found.st_uid == geteuid(), (found.st_mode & mode_t(0o077)) == 0
        else { throw CompanionOwnedPackError.unsafeCleanup }
        if (found.st_mode & mode_t(S_IFMT)) == mode_t(S_IFREG), found.st_nlink != 1 {
            throw CompanionOwnedPackError.unsafeCleanup
        }
    }

    private static func removeFile(_ file: Leaf, parent: Int32) throws {
        try requireIdentity(parent: parent, name: file.name, expected: file.info)
        guard file.name.withCString({ unlinkat(parent, $0, 0) }) == 0
        else { throw CompanionOwnedPackError.cleanupFailed }
    }
}

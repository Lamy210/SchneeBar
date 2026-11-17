import Darwin
import Foundation

/// Synchronous, descriptor-relative reader for one user-selected directory.
/// Bounded PNG sequence enumeration; no archive extraction, copy, or persistence.
/// Not Sendable: keep the reader inside one background worker.
public final class CompanionPackDirectory {
    private let root: Int32
    private let device: dev_t

    public init(_ url: URL) throws {
        guard url.isFileURL, url.path.hasPrefix("/"),
              url.host == nil || url.host == "" || url.host == "localhost",
              url.pathExtension.lowercased() == "schneerunner" else {
            throw CompanionPackError.invalidDirectory
        }
        try Task.checkCancellation()
        let fd = url.withUnsafeFileSystemRepresentation { path -> Int32 in
            guard let path else { return -1 }
            return Darwin.open(path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
        }
        guard fd >= 0 else { throw CompanionPackError.openFailed }
        var info = stat()
        guard fstat(fd, &info) == 0, (info.st_mode & mode_t(S_IFMT)) == mode_t(S_IFDIR) else {
            _ = Darwin.close(fd)
            throw CompanionPackError.invalidDirectory
        }
        root = fd
        device = info.st_dev
    }

    deinit { _ = Darwin.close(root) }

    public func manifest() throws -> CompanionPackManifest {
        try CompanionPackManifest.decode(read(
            CompanionPackPath(CompanionPackManifest.filename),
            maximumBytes: CompanionPackManifest.maximumBytes
        ))
    }

    /// Only files explicitly addressed by a validated relative path. Root
    /// selection is the trust boundary; ancestors of the selected root are
    /// not claimed symlink-free. Open descriptors pin actual objects.
    public func read(_ path: CompanionPackPath, maximumBytes: Int) throws -> Data {
        guard let leaf = path.components.last else { throw CompanionPackError.unsafePath }
        let parent = try openDirectory(Array(path.components.dropLast()))
        defer { if parent != root { _ = Darwin.close(parent) } }
        return try readFile(parent: parent, leaf: leaf, maximumBytes: maximumBytes)
    }

    /// Enumerate only a manifest-declared PNG sequence directory, count
    /// hidden entries toward the scan cap, and read from that same open
    /// directory descriptor. Never reacquire a URL by enumerated name.
    func readPNGSequence(_ path: CompanionPackPath, maximumBytes: Int,
                         maximumFrames: Int) throws -> [Data] {
        guard maximumFrames >= 2, maximumFrames <= CompanionImageDecoder.maximumFrames else {
            throw CompanionAnimatedPackError.frameBudget
        }
        let fd = try openDirectory(path.components)
        guard fd != root else { throw CompanionPackError.unsafePath }
        guard let stream = fdopendir(fd) else {
            _ = Darwin.close(fd)
            throw CompanionPackError.openFailed
        }
        defer { _ = closedir(stream) } // owns fd
        var before = stat()
        guard fstat(fd, &before) == 0 else { throw CompanionPackError.unsafeResource }
        var names: [String] = []
        var scanned = 0
        while true {
            try Task.checkCancellation()
            errno = 0
            guard let item = readdir(stream) else {
                guard errno == 0 else { throw CompanionPackError.unsafeResource }
                break
            }
            scanned += 1
            guard scanned <= 256 else { throw CompanionAnimatedPackError.frameBudget }
            let length = Int(item.pointee.d_namlen)
            let name: String? = withUnsafeBytes(of: &item.pointee.d_name) { raw in
                guard length > 0, length <= 255, length < raw.count,
                      raw[length] == 0, !raw.prefix(length).contains(0)
                else { return nil }
                return String(bytes: raw.prefix(length), encoding: .utf8)
            }
            guard let name else { throw CompanionPackError.unsafePath }
            if name.hasPrefix(".") { continue }
            let leafPath = try CompanionPackPath((path.components + [name]).joined(separator: "/"))
            guard leafPath.components.count == path.components.count + 1,
                  name.lowercased().hasSuffix(".png") else {
                throw CompanionAnimatedPackError.formatMismatch
            }
            guard names.count < maximumFrames else { throw CompanionAnimatedPackError.frameBudget }
            names.append(name)
        }
        guard names.count >= 2 else { throw CompanionAnimatedPackError.frameBudget }
        let locale = Locale(identifier: "en_US_POSIX")
        names.sort {
            let order = $0.compare($1, options: [.numeric, .caseInsensitive], locale: locale)
            if order == .orderedSame { return $0.utf8.lexicographicallyPrecedes($1.utf8) }
            return order == .orderedAscending
        }

        var remaining = maximumBytes
        var frames: [Data] = []
        for name in names {
            try Task.checkCancellation()
            guard remaining > 0 else { throw CompanionAnimatedPackError.encodedBudget }
            let bytes = try readFile(parent: fd, leaf: name, maximumBytes: remaining)
            remaining -= bytes.count
            frames.append(bytes)
        }
        var after = stat()
        guard fstat(fd, &after) == 0,
              before.st_dev == after.st_dev, before.st_ino == after.st_ino,
              before.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec,
              before.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec,
              before.st_ctimespec.tv_sec == after.st_ctimespec.tv_sec,
              before.st_ctimespec.tv_nsec == after.st_ctimespec.tv_nsec
        else { throw CompanionFileReadError.changedDuringRead }
        return frames
    }

    /// Caller closes the returned descriptor unless it is the owned root.
    private func openDirectory(_ components: [String]) throws -> Int32 {
        var parent = root
        var transferred = false
        defer { if !transferred && parent != root { _ = Darwin.close(parent) } }
        for component in components {
            try Task.checkCancellation()
            let child = component.withCString {
                Darwin.openat(parent, $0, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
            }
            guard child >= 0 else { throw CompanionPackError.openFailed }
            var info = stat()
            guard fstat(child, &info) == 0, info.st_dev == device,
                  (info.st_mode & mode_t(S_IFMT)) == mode_t(S_IFDIR) else {
                _ = Darwin.close(child)
                throw CompanionPackError.unsafeResource
            }
            if parent != root { _ = Darwin.close(parent) }
            parent = child
        }
        transferred = true
        return parent
    }

    private func readFile(parent: Int32, leaf: String, maximumBytes: Int) throws -> Data {
        try Task.checkCancellation()
        let fd = leaf.withCString {
            Darwin.openat(parent, $0, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
        }
        guard fd >= 0 else { throw CompanionPackError.openFailed }
        defer { _ = Darwin.close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_dev == device,
              (info.st_mode & mode_t(S_IFMT)) == mode_t(S_IFREG), info.st_nlink == 1
        else { throw CompanionPackError.unsafeResource }
        return try CompanionFileReader.readOpenedFile(fd, limit: maximumBytes, requireSingleLink: true)
    }
}

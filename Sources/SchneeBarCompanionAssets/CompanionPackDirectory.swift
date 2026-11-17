import Darwin
import Foundation

/// Synchronous, descriptor-relative reader for one user-selected directory.
/// No directory enumeration, archive extraction, copy, or persistence.
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
        var parent = root
        defer { if parent != root { _ = Darwin.close(parent) } }
        for component in path.components.dropLast() {
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
        try Task.checkCancellation()
        guard let leaf = path.components.last else { throw CompanionPackError.unsafePath }
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

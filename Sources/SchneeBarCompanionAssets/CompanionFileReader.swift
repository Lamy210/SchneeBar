import Darwin
import Foundation

public enum CompanionFileReadError: Error, Equatable {
    case invalidURL
    case openFailed
    case notRegularFile
    case metadataUnavailable
    case invalidSize
    case changedDuringRead
    case readFailed
}

/// Read a single explicitly selected local file. No archive, directory, or
/// manifest path is accepted. An opened descriptor is the only read authority.
public enum CompanionFileReader {
    public static func read(_ url: URL) throws -> Data {
        guard url.isFileURL, url.path.hasPrefix("/"),
              url.host == nil || url.host == "" || url.host == "localhost" else {
            throw CompanionFileReadError.invalidURL
        }
        try Task.checkCancellation()
        let descriptor = url.withUnsafeFileSystemRepresentation { path -> Int32 in
            guard let path else { return -1 }
            return Darwin.open(path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK)
        }
        guard descriptor >= 0 else { throw CompanionFileReadError.openFailed }
        defer { _ = Darwin.close(descriptor) }
        return try readOpenedFile(descriptor)
    }

    private static func metadata(_ fd: Int32) throws -> stat {
        var info = stat()
        guard fstat(fd, &info) == 0 else { throw CompanionFileReadError.metadataUnavailable }
        guard (info.st_mode & mode_t(S_IFMT)) == mode_t(S_IFREG) else {
            throw CompanionFileReadError.notRegularFile
        }
        return info
    }

    // Caller retains ownership of the descriptor. Pack reads impose a
    // stricter size and link policy than explicitly selected single files.
    static func readOpenedFile(
        _ fd: Int32, limit: Int = CompanionImageDecoder.maximumBytes,
        requireSingleLink: Bool = false
    ) throws -> Data {
        let before = try metadata(fd)
        guard (1...CompanionImageDecoder.maximumBytes).contains(limit) else {
            throw CompanionFileReadError.invalidSize
        }
        if requireSingleLink, before.st_nlink != 1 {
            throw CompanionPackError.unsafeResource
        }
        guard before.st_size > 0, before.st_size <= off_t(limit) else {
            throw CompanionFileReadError.invalidSize
        }

        var result = Data()
        result.reserveCapacity(Int(before.st_size))
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            try Task.checkCancellation()
            // Read at most one extra byte to detect growth beyond the cap.
            let count = min(buffer.count, limit - result.count + 1)
            let received = buffer.withUnsafeMutableBytes { bytes in
                Darwin.read(fd, bytes.baseAddress, count)
            }
            if received < 0 {
                if errno == EINTR { continue }
                throw CompanionFileReadError.readFailed
            }
            if received == 0 { break }
            guard received <= limit - result.count else {
                throw CompanionFileReadError.invalidSize
            }
            result.append(contentsOf: buffer.prefix(received))
        }

        let after = try metadata(fd)
        if requireSingleLink, after.st_nlink != 1 {
            throw CompanionPackError.unsafeResource
        }
        guard before.st_dev == after.st_dev, before.st_ino == after.st_ino,
              before.st_size == after.st_size, after.st_size == off_t(result.count),
              before.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec,
              before.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec,
              before.st_ctimespec.tv_sec == after.st_ctimespec.tv_sec,
              before.st_ctimespec.tv_nsec == after.st_ctimespec.tv_nsec else {
            throw CompanionFileReadError.changedDuringRead
        }
        try Task.checkCancellation()
        return result
    }
}

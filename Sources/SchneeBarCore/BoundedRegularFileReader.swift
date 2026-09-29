import Darwin
import Foundation

public enum BoundedRegularFileReadError: Error, Equatable, Sendable {
    case unsafeBackingFile
    case payloadTooLarge
}

public enum BoundedRegularFileReader {
    private static let chunkSize = 64 * 1024

    public static func readIfPresent(
        at fileURL: URL,
        maximumBytes: Int
    ) throws -> Data? {
        precondition(
            maximumBytes >= 0 && maximumBytes < Int.max
        )

        var descriptor = Int32(-1)
        let hasFileSystemRepresentation =
            fileURL.withUnsafeFileSystemRepresentation { path in
                guard let path else { return false }
                descriptor = Darwin.open(
                    path,
                    O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK
                )
                return true
            }
        guard hasFileSystemRepresentation else {
            throw BoundedRegularFileReadError.unsafeBackingFile
        }
        guard descriptor >= 0 else {
            switch errno {
            case ENOENT:
                return nil
            case ELOOP, ENOTDIR:
                throw BoundedRegularFileReadError.unsafeBackingFile
            default:
                throw POSIXError(
                    POSIXErrorCode(rawValue: errno) ?? .EIO
                )
            }
        }
        defer {
            Darwin.close(descriptor)
        }

        var metadata = stat()
        guard Darwin.fstat(descriptor, &metadata) == 0 else {
            throw POSIXError(
                POSIXErrorCode(rawValue: errno) ?? .EIO
            )
        }
        guard metadata.st_mode & S_IFMT == S_IFREG,
              metadata.st_nlink == 1
        else {
            throw BoundedRegularFileReadError.unsafeBackingFile
        }
        guard metadata.st_size >= 0,
              metadata.st_size <= off_t(maximumBytes)
        else {
            throw BoundedRegularFileReadError.payloadTooLarge
        }

        var data = Data()
        data.reserveCapacity(
            min(maximumBytes, Int(metadata.st_size))
        )

        var buffer = [UInt8](
            repeating: 0,
            count: min(Self.chunkSize, maximumBytes + 1)
        )
        while data.count <= maximumBytes {
            let remaining = maximumBytes + 1 - data.count
            let requested = min(buffer.count, remaining)
            let count = buffer.withUnsafeMutableBytes { bytes in
                Darwin.read(
                    descriptor,
                    bytes.baseAddress,
                    requested
                )
            }

            if count > 0 {
                data.append(
                    contentsOf: buffer.prefix(Int(count))
                )
                continue
            }
            if count == 0 {
                break
            }
            if errno == EINTR {
                continue
            }
            throw POSIXError(
                POSIXErrorCode(rawValue: errno) ?? .EIO
            )
        }

        guard data.count <= maximumBytes else {
            throw BoundedRegularFileReadError.payloadTooLarge
        }
        return data
    }
}

import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

public enum GitHubCredentialEnrollmentFileStoreError: Error, Equatable, Sendable {
    case unsafeStorage
    case unsupportedFormat
    case corruptFile
    case tooLarge
    case io(Int32)
}

/// Opt-in store for NONSECRET enrollment metadata. A caller must provision
/// an existing app-owned 0700 directory under trusted Application Support
/// parents. This adapter is not yet connected to shipping authentication.
public struct GitHubCredentialEnrollmentFileJournalStore:
    GitHubCredentialEnrollmentJournalPersistence
{
    public static let maximumBytes = 1_048_576
    private static let dataName = "enrollments-v1.json"
    private static let lockName = "enrollments-v1.lock"
    private let directoryURL: URL

    public init(directoryURL: URL) {
        self.directoryURL = directoryURL
    }

    public func load() throws -> [GitHubCredentialEnrollmentLifecycle] {
        try withLockedDirectory(exclusive: false) { fd in
            try readSnapshot(fd)
        }
    }

    public func compareAndReplace(
        expected: [GitHubCredentialEnrollmentLifecycle],
        next: [GitHubCredentialEnrollmentLifecycle]
    ) throws {
        try validate(next)
        try withLockedDirectory(exclusive: true) { fd in
            let current = try readSnapshot(fd)
            guard current == expected else {
                throw GitHubCredentialEnrollmentJournalError.staleSnapshot
            }
            try verifyAppendOnlyTransitions(current: current, proposed: next)
            let ordered = next.sorted {
                $0.enrollmentID.uuidString < $1.enrollmentID.uuidString
            }
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            let data = try encoder.encode(Envelope(version: 1, records: ordered))
            guard data.count <= Self.maximumBytes else {
                throw GitHubCredentialEnrollmentFileStoreError.tooLarge
            }
            try atomicWrite(data, directoryFD: fd)
        }
    }

    /// No caller can remove a previous enrollment or rewrite identity.
    /// Persisted tombstones are irreversible; each changed record must be
    /// exactly one generation ahead along an allowed phase transition.
    private func verifyAppendOnlyTransitions(
        current: [GitHubCredentialEnrollmentLifecycle],
        proposed: [GitHubCredentialEnrollmentLifecycle]
    ) throws {
        let nextByID = Dictionary(uniqueKeysWithValues:
            proposed.map { ($0.enrollmentID, $0) }
        )
        let existingIDs = Set(current.map(\.enrollmentID))
        for old in current {
            guard let updated = nextByID[old.enrollmentID] else {
                throw GitHubCredentialEnrollmentJournalError.invalidSnapshot
            }
            if updated == old { continue }
            guard updated.purpose == old.purpose,
                  updated.canonicalWebOrigin == old.canonicalWebOrigin,
                  updated.numericAccountID == old.numericAccountID,
                  updated.appClientID == old.appClientID,
                  let valid = try? old.transitioned(
                      to: updated.phase, expectedGeneration: old.generation
                  ),
                  valid == updated
            else {
                throw GitHubCredentialEnrollmentJournalError.invalidSnapshot
            }
        }
        for entry in proposed where !existingIDs.contains(entry.enrollmentID) {
            guard entry.generation == 1,
                  entry.phase == .prepared || entry.phase == .legacyActive
            else {
                throw GitHubCredentialEnrollmentJournalError.invalidSnapshot
            }
        }
    }

    private struct Envelope: Codable {
        let version: Int
        let records: [GitHubCredentialEnrollmentLifecycle]
    }

    private func validate(
        _ records: [GitHubCredentialEnrollmentLifecycle]
    ) throws {
        var ids = Set<UUID>()
        for record in records {
            guard record.isValidPersistedSnapshot(),
                  ids.insert(record.enrollmentID).inserted
            else {
                throw GitHubCredentialEnrollmentJournalError.invalidSnapshot
            }
        }
    }

    private func readSnapshot(_ dirFD: Int32) throws
        -> [GitHubCredentialEnrollmentLifecycle]
    {
        let fd = Self.dataName.withCString {
            openat(dirFD, $0, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        }
        if fd < 0 {
            if errno == ENOENT { return [] }
            throw GitHubCredentialEnrollmentFileStoreError.io(errno)
        }
        defer { _ = close(fd) }
        try verifyOwnedFile(fd)

        var contents = Data()
        var buffer = [UInt8](repeating: 0, count: 8192)
        while true {
            let count = buffer.withUnsafeMutableBytes {
                read(fd, $0.baseAddress, $0.count)
            }
            if count < 0 {
                if errno == EINTR { continue }
                throw GitHubCredentialEnrollmentFileStoreError.io(errno)
            }
            if count == 0 { break }
            guard contents.count + count <= Self.maximumBytes else {
                throw GitHubCredentialEnrollmentFileStoreError.tooLarge
            }
            contents.append(contentsOf: buffer.prefix(count))
        }

        guard let envelope = try? JSONDecoder().decode(
            Envelope.self, from: contents
        ) else {
            throw GitHubCredentialEnrollmentFileStoreError.corruptFile
        }
        guard envelope.version == 1 else {
            throw GitHubCredentialEnrollmentFileStoreError.unsupportedFormat
        }
        try validate(envelope.records)
        return envelope.records.sorted {
            $0.enrollmentID.uuidString < $1.enrollmentID.uuidString
        }
    }

    private func verifyOwnedFile(_ fd: Int32) throws {
        var info = stat()
        guard fstat(fd, &info) == 0 else {
            throw GitHubCredentialEnrollmentFileStoreError.io(errno)
        }
        guard info.st_uid == geteuid(),
              (info.st_mode & mode_t(S_IFMT)) == mode_t(S_IFREG),
              info.st_nlink == 1,
              (info.st_mode & mode_t(0o077)) == 0
        else {
            throw GitHubCredentialEnrollmentFileStoreError.unsafeStorage
        }
        guard info.st_size >= 0,
              info.st_size <= Int64(Self.maximumBytes)
        else {
            throw GitHubCredentialEnrollmentFileStoreError.tooLarge
        }
    }

    private func withLockedDirectory<T>(
        exclusive: Bool,
        _ body: (Int32) throws -> T
    ) throws -> T {
        let dirFD = directoryURL.path.withCString {
            open($0, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        }
        guard dirFD >= 0 else {
            throw GitHubCredentialEnrollmentFileStoreError.io(errno)
        }
        defer { _ = close(dirFD) }
        var info = stat()
        guard fstat(dirFD, &info) == 0 else {
            throw GitHubCredentialEnrollmentFileStoreError.io(errno)
        }
        guard info.st_uid == geteuid(),
              (info.st_mode & mode_t(S_IFMT)) == mode_t(S_IFDIR),
              (info.st_mode & mode_t(0o077)) == 0
        else {
            throw GitHubCredentialEnrollmentFileStoreError.unsafeStorage
        }

        // The lock inode is persistent; we never unlink or rename it.
        let lockFD = Self.lockName.withCString {
            openat(dirFD, $0,
                O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC,
                mode_t(0o600))
        }
        guard lockFD >= 0 else {
            throw GitHubCredentialEnrollmentFileStoreError.io(errno)
        }
        defer { _ = close(lockFD) }
        try verifyOwnedFile(lockFD)

        let operation = exclusive ? LOCK_EX : LOCK_SH
        while flock(lockFD, operation) != 0 {
            if errno == EINTR { continue }
            throw GitHubCredentialEnrollmentFileStoreError.io(errno)
        }
        defer { _ = flock(lockFD, LOCK_UN) }
        return try body(dirFD)
    }

    private func atomicWrite(
        _ data: Data,
        directoryFD: Int32
    ) throws {
        let temp = ".enrollments-" + UUID().uuidString + ".tmp"
        let fd = temp.withCString {
            openat(directoryFD, $0,
                O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC,
                mode_t(0o600))
        }
        guard fd >= 0 else {
            throw GitHubCredentialEnrollmentFileStoreError.io(errno)
        }
        var renamed = false
        defer {
            _ = close(fd)
            if !renamed {
                _ = temp.withCString { unlinkat(directoryFD, $0, 0) }
            }
        }

        try data.withUnsafeBytes { raw in
            var offset = 0
            while offset < raw.count {
                let amount = write(
                    fd, raw.baseAddress!.advanced(by: offset),
                    raw.count - offset
                )
                if amount < 0 {
                    if errno == EINTR { continue }
                    throw GitHubCredentialEnrollmentFileStoreError.io(errno)
                }
                guard amount > 0 else {
                    throw GitHubCredentialEnrollmentFileStoreError.io(EIO)
                }
                offset += amount
            }
        }
        guard fsync(fd) == 0 else {
            throw GitHubCredentialEnrollmentFileStoreError.io(errno)
        }
        let renamedStatus = temp.withCString { source in
            Self.dataName.withCString { target in
                renameat(directoryFD, source, directoryFD, target)
            }
        }
        guard renamedStatus == 0 else {
            throw GitHubCredentialEnrollmentFileStoreError.io(errno)
        }
        renamed = true
        guard fsync(directoryFD) == 0 else {
            // Rename may already be visible. Caller must reload its cache.
            throw GitHubCredentialEnrollmentFileStoreError.io(errno)
        }
    }
}

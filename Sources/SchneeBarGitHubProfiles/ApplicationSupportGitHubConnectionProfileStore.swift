import Darwin
import Foundation
import SchneeBarGitHub

public enum GitHubConnectionProfileStoreError: Error, Equatable, Sendable {
    case unsupportedSchemaVersion(Int)
    case invalidBackingFile
    case payloadTooLarge
}

public actor ApplicationSupportGitHubConnectionProfileStore: GitHubConnectionProfileStore {
    // Internal defensive budget for app-owned non-secret metadata. This is not
    // a GitHub protocol limit and is intentionally generous for large selected
    // repository sets while preventing an unbounded local file read.
    private static let maximumPersistedBytes = 8 * 1024 * 1024

    private let fileURL: URL
    private let fileManager: FileManager

    public init(
        fileURL: URL? = nil,
        fileManager: FileManager = .default
    ) {
        self.fileManager = fileManager
        self.fileURL = fileURL ?? Self.defaultFileURL(fileManager: fileManager)
    }

    public func loadAll() async throws -> [GitHubConnectionProfile] {
        try readProfiles()
    }

    public func load(id: UUID) async throws -> GitHubConnectionProfile? {
        try readProfiles().first(where: { $0.id == id })
    }

    public func save(_ profile: GitHubConnectionProfile) async throws {
        var profiles = try readProfiles()
        if let index = profiles.firstIndex(where: { $0.id == profile.id }) {
            profiles[index] = profile
        } else {
            profiles.append(profile)
        }
        try writeProfiles(profiles)
    }

    public func delete(id: UUID) async throws {
        var profiles = try readProfiles()
        let originalCount = profiles.count
        profiles.removeAll(where: { $0.id == id })
        guard profiles.count != originalCount else { return }
        try writeProfiles(profiles)
    }

    private func readProfiles() throws -> [GitHubConnectionProfile] {
        guard let data = try readPersistedDataIfPresent() else {
            return []
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let payload = try decoder.decode(PersistedProfiles.self, from: data)
        guard payload.schemaVersion == PersistedProfiles.currentSchemaVersion else {
            throw GitHubConnectionProfileStoreError.unsupportedSchemaVersion(payload.schemaVersion)
        }
        return payload.profiles
    }

    private func readPersistedDataIfPresent() throws -> Data? {
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
            throw GitHubConnectionProfileStoreError.invalidBackingFile
        }
        guard descriptor >= 0 else {
            if errno == ENOENT {
                return nil
            }
            if errno == ELOOP {
                throw GitHubConnectionProfileStoreError.invalidBackingFile
            }
            throw POSIXError(
                POSIXErrorCode(rawValue: errno) ?? .EIO
            )
        }

        let handle = FileHandle(
            fileDescriptor: descriptor,
            closeOnDealloc: true
        )
        var metadata = stat()
        guard fstat(descriptor, &metadata) == 0 else {
            throw POSIXError(
                POSIXErrorCode(rawValue: errno) ?? .EIO
            )
        }
        guard metadata.st_mode & S_IFMT == S_IFREG,
              metadata.st_nlink == 1
        else {
            throw GitHubConnectionProfileStoreError.invalidBackingFile
        }
        guard metadata.st_size >= 0,
              metadata.st_size <= off_t(Self.maximumPersistedBytes)
        else {
            throw GitHubConnectionProfileStoreError.payloadTooLarge
        }

        var data = Data()
        while data.count <= Self.maximumPersistedBytes {
            let remaining = Self.maximumPersistedBytes + 1 - data.count
            guard let chunk = try handle.read(upToCount: remaining),
                  !chunk.isEmpty
            else {
                break
            }
            data.append(chunk)
        }
        guard data.count <= Self.maximumPersistedBytes else {
            throw GitHubConnectionProfileStoreError.payloadTooLarge
        }
        return data
    }

    private func writeProfiles(_ profiles: [GitHubConnectionProfile]) throws {
        let directory = fileURL.deletingLastPathComponent()
        try fileManager.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        try? fileManager.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: directory.path
        )

        let payload = PersistedProfiles(
            schemaVersion: PersistedProfiles.currentSchemaVersion,
            profiles: profiles
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(payload)
        guard data.count <= Self.maximumPersistedBytes else {
            throw GitHubConnectionProfileStoreError.payloadTooLarge
        }
        try data.write(to: fileURL, options: .atomic)
        try? fileManager.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: fileURL.path
        )
    }

    private static func defaultFileURL(fileManager: FileManager) -> URL {
        let applicationSupport = fileManager.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? fileManager.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support", isDirectory: true)

        return applicationSupport
            .appendingPathComponent("SchneeBar", isDirectory: true)
            .appendingPathComponent("github-connections-v1.json", isDirectory: false)
    }
}

private struct PersistedProfiles: Codable {
    static let currentSchemaVersion = 1

    let schemaVersion: Int
    let profiles: [GitHubConnectionProfile]
}

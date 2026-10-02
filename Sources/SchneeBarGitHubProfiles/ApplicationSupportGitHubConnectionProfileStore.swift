import Foundation
import SchneeBarCore
import SchneeBarGitHub

public enum GitHubConnectionProfileStoreError: Error, Equatable, Sendable {
    case unsupportedSchemaVersion(Int)
    case invalidBackingFile
    case payloadTooLarge
    case invalidConnectionIdentity(UUID)
    case invalidClientID(UUID)
    case duplicateConnectionID(UUID)
    case connectionIdentityChanged(UUID)
    case duplicateConnectionIdentity(
        existingID: UUID,
        incomingID: UUID
    )
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
        if let clientID = profile.clientID,
           !GitHubClientIDPolicy.isValid(clientID)
        {
            throw GitHubConnectionProfileStoreError
                .invalidClientID(profile.id)
        }

        guard GitHubConnectionProfileIdentityPolicy
            .hasCanonicalIdentity(profile)
        else {
            throw GitHubConnectionProfileStoreError
                .invalidConnectionIdentity(profile.id)
        }

        var profiles = try readProfiles()
        let matchingConnectionIDs = profiles.indices.filter {
            profiles[$0].id == profile.id
        }
        guard matchingConnectionIDs.count <= 1 else {
            throw GitHubConnectionProfileStoreError
                .duplicateConnectionID(profile.id)
        }

        if let existingID =
            GitHubConnectionProfileIdentityPolicy.conflictingProfileID(
                for: profile,
                in: profiles
            )
        {
            throw GitHubConnectionProfileStoreError
                .duplicateConnectionIdentity(
                    existingID: existingID,
                    incomingID: profile.id
                )
        }

        if let index = matchingConnectionIDs.first {
            let existingIdentity =
                GitHubConnectionProfileIdentityPolicy.identity(
                    for: profiles[index]
                )
            let incomingIdentity =
                GitHubConnectionProfileIdentityPolicy.identity(
                    for: profile
                )
            guard existingIdentity == incomingIdentity else {
                throw GitHubConnectionProfileStoreError
                    .connectionIdentityChanged(profile.id)
            }
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
        do {
            return try BoundedRegularFileReader.readIfPresent(
                at: fileURL,
                maximumBytes: Self.maximumPersistedBytes
            )
        } catch BoundedRegularFileReadError.unsafeBackingFile {
            throw GitHubConnectionProfileStoreError.invalidBackingFile
        } catch BoundedRegularFileReadError.payloadTooLarge {
            throw GitHubConnectionProfileStoreError.payloadTooLarge
        }
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

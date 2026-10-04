import Foundation
import SchneeBarCore
import SchneeBarGitHub

public enum GitHubConnectionProfileStoreError: Error, Equatable, Sendable {
    case unsupportedSchemaVersion(Int)
    case invalidBackingFile
    case payloadTooLarge
    case duplicateConnectionIdentity
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
        try validateUniqueConnectionIdentities(profiles)
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
        try validateUniqueConnectionIdentities(payload.profiles)
        return payload.profiles
    }

    private func validateUniqueConnectionIdentities(
        _ profiles: [GitHubConnectionProfile]
    ) throws {
        var identities: Set<PersistedConnectionIdentity> = []
        identities.reserveCapacity(profiles.count)

        for profile in profiles {
            let identity = try persistedConnectionIdentity(for: profile)
            guard identities.insert(identity).inserted else {
                throw GitHubConnectionProfileStoreError.duplicateConnectionIdentity
            }
        }
    }

    private func persistedConnectionIdentity(
        for profile: GitHubConnectionProfile
    ) throws -> PersistedConnectionIdentity {
        let endpoints: GitHubEndpointSet
        do {
            endpoints = try GitHubEndpointResolver.resolve(
                deploymentKind: profile.connection.deploymentKind,
                webBaseURL: profile.connection.webBaseURL
            )
        } catch {
            throw GitHubConnectionProfileStoreError.invalidBackingFile
        }

        return PersistedConnectionIdentity(
            deploymentKind: profile.connection.deploymentKind.rawValue,
            canonicalWebBaseURL: endpoints.webBaseURL.absoluteString,
            accountID: profile.account.id
        )
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

private struct PersistedConnectionIdentity: Hashable {
    let deploymentKind: String
    let canonicalWebBaseURL: String
    let accountID: String
}

private struct PersistedProfiles: Codable {
    static let currentSchemaVersion = 1

    let schemaVersion: Int
    let profiles: [GitHubConnectionProfile]
}

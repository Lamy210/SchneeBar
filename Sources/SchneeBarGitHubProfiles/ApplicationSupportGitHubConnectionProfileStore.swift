import Foundation
import SchneeBarGitHub

public enum GitHubConnectionProfileStoreError: Error, Equatable, Sendable {
    case unsupportedSchemaVersion(Int)
}

public actor ApplicationSupportGitHubConnectionProfileStore: GitHubConnectionProfileStore {
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
        guard fileManager.fileExists(atPath: fileURL.path) else {
            return []
        }

        let data = try Data(contentsOf: fileURL)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let payload = try decoder.decode(PersistedProfiles.self, from: data)
        guard payload.schemaVersion == PersistedProfiles.currentSchemaVersion else {
            throw GitHubConnectionProfileStoreError.unsupportedSchemaVersion(payload.schemaVersion)
        }
        return payload.profiles
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

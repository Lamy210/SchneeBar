import Foundation
import SchneeBarGitHub
import SchneeBarGitHubProfiles
import Testing

@Test
func savingCanonicalEquivalentEndpointForSameStableAccountIsRejected() async throws {
    let context = try duplicateIdentityStore()
    defer { try? FileManager.default.removeItem(at: context.directory) }

    let original = try duplicateIdentityProfile(
        id: UUID(uuidString: "71000000-0000-0000-0000-000000000001")!,
        endpoint: "https://github.com",
        accountID: "42",
        login: "octocat"
    )
    let duplicate = try duplicateIdentityProfile(
        id: UUID(uuidString: "71000000-0000-0000-0000-000000000002")!,
        endpoint: "https://github.com:443/",
        accountID: "42",
        login: "renamed-octocat"
    )

    try await context.store.save(original)
    let before = try Data(contentsOf: context.fileURL)

    await #expect(
        throws: GitHubConnectionProfileStoreError.duplicateConnectionIdentity
    ) {
        try await context.store.save(duplicate)
    }

    #expect(try Data(contentsOf: context.fileURL) == before)
    #expect(try await context.store.loadAll() == [original])
}

@Test
func loadingPersistedDuplicateConnectionIdentityIsRejected() async throws {
    let context = try duplicateIdentityStore()
    defer { try? FileManager.default.removeItem(at: context.directory) }

    let original = try duplicateIdentityProfile(
        id: UUID(uuidString: "72000000-0000-0000-0000-000000000001")!,
        endpoint: "https://github.com",
        accountID: "42",
        login: "octocat"
    )
    let duplicate = try duplicateIdentityProfile(
        id: UUID(uuidString: "72000000-0000-0000-0000-000000000002")!,
        endpoint: "https://GITHUB.COM:443/",
        accountID: "42",
        login: "renamed-octocat"
    )

    try FileManager.default.createDirectory(
        at: context.directory,
        withIntermediateDirectories: true
    )
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    encoder.outputFormatting = [.sortedKeys]
    let data = try encoder.encode(
        DuplicateIdentityPersistedProfiles(
            schemaVersion: 1,
            profiles: [original, duplicate]
        )
    )
    try data.write(to: context.fileURL)

    await #expect(
        throws: GitHubConnectionProfileStoreError.duplicateConnectionIdentity
    ) {
        try await context.store.loadAll()
    }
}

private struct DuplicateIdentityStoreContext {
    let directory: URL
    let fileURL: URL
    let store: ApplicationSupportGitHubConnectionProfileStore
}

private struct DuplicateIdentityPersistedProfiles: Codable {
    let schemaVersion: Int
    let profiles: [GitHubConnectionProfile]
}

private func duplicateIdentityStore() throws -> DuplicateIdentityStoreContext {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent(
            "SchneeBar-duplicate-profile-tests-\(UUID().uuidString)",
            isDirectory: true
        )
    let fileURL = directory.appendingPathComponent(
        "connections.json",
        isDirectory: false
    )
    return DuplicateIdentityStoreContext(
        directory: directory,
        fileURL: fileURL,
        store: ApplicationSupportGitHubConnectionProfileStore(
            fileURL: fileURL
        )
    )
}

private func duplicateIdentityProfile(
    id: UUID,
    endpoint: String,
    accountID: String,
    login: String
) throws -> GitHubConnectionProfile {
    GitHubConnectionProfile(
        connection: GitHubConnection(
            id: id,
            displayName: "GitHub",
            deploymentKind: .githubDotCom,
            webBaseURL: try #require(URL(string: endpoint)),
            apiVersion: "2026-03-10"
        ),
        account: GitHubAccountIdentity(
            id: accountID,
            login: login
        ),
        authenticationMethod: .deviceFlow,
        clientID: "Iv1.public-client",
        repositorySelection: .allAccessible,
        isEnabled: true,
        createdAt: Date(timeIntervalSince1970: 1_000),
        lastConnectedAt: Date(timeIntervalSince1970: 1_500)
    )
}

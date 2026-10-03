import Foundation
import SchneeBarGitHub
import SchneeBarGitHubProfiles
import Testing

@Test
func profileStoreRejectsDifferentUUIDForSameEndpointAndAccount() async throws {
    let context = try identityStoreContext()
    defer { try? FileManager.default.removeItem(at: context.directory) }

    let first = try identityProfile(
        connectionID: UUID(
            uuidString: "51000000-0000-0000-0000-000000000001"
        )!
    )
    let duplicate = try identityProfile(
        connectionID: UUID(
            uuidString: "51000000-0000-0000-0000-000000000002"
        )!
    )

    try await context.store.save(first)

    await #expect(
        throws: GitHubConnectionProfileStoreError.duplicateLogicalIdentity
    ) {
        try await context.store.save(duplicate)
    }

    #expect(try await context.store.loadAll() == [first])
}

@Test
func profileStoreRejectsPersistedDuplicateLogicalIdentity() async throws {
    let context = try identityStoreContext()
    defer { try? FileManager.default.removeItem(at: context.directory) }

    let first = try identityProfile(
        connectionID: UUID(
            uuidString: "52000000-0000-0000-0000-000000000001"
        )!
    )
    let duplicate = try identityProfile(
        connectionID: UUID(
            uuidString: "52000000-0000-0000-0000-000000000002"
        )!
    )
    try FileManager.default.createDirectory(
        at: context.directory,
        withIntermediateDirectories: true
    )
    let payload = IdentityPersistedProfiles(
        schemaVersion: 1,
        profiles: [first, duplicate]
    )
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    try encoder.encode(payload).write(to: context.fileURL)

    await #expect(
        throws: GitHubConnectionProfileStoreError.duplicateLogicalIdentity
    ) {
        try await context.store.loadAll()
    }
}

private struct IdentityStoreContext {
    let directory: URL
    let fileURL: URL
    let store: ApplicationSupportGitHubConnectionProfileStore
}

private struct IdentityPersistedProfiles: Encodable {
    let schemaVersion: Int
    let profiles: [GitHubConnectionProfile]
}

private func identityStoreContext() throws -> IdentityStoreContext {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent(
            "SchneeBar-profile-identity-tests-\(UUID().uuidString)",
            isDirectory: true
        )
    let fileURL = directory.appendingPathComponent(
        "connections.json",
        isDirectory: false
    )
    return IdentityStoreContext(
        directory: directory,
        fileURL: fileURL,
        store: ApplicationSupportGitHubConnectionProfileStore(
            fileURL: fileURL
        )
    )
}

private func identityProfile(
    connectionID: UUID
) throws -> GitHubConnectionProfile {
    let connection = GitHubConnection(
        id: connectionID,
        displayName: "GitHub.com",
        deploymentKind: .githubDotCom,
        webBaseURL: try #require(URL(string: "https://github.com")),
        serverVersion: nil,
        apiVersion: "2026-03-10"
    )
    return GitHubConnectionProfile(
        connection: connection,
        account: GitHubAccountIdentity(
            id: "42",
            login: "octocat"
        ),
        authenticationMethod: .deviceFlow,
        clientID: "Iv1.public-client",
        repositorySelection: .allAccessible,
        isEnabled: true,
        createdAt: Date(timeIntervalSince1970: 1_000),
        lastConnectedAt: Date(timeIntervalSince1970: 1_500)
    )
}

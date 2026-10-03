import Foundation
import SchneeBarGitHub
import SchneeBarGitHubProfiles
import Testing

@Test
func savingSameEndpointAndStableAccountWithDifferentConnectionIDIsRejected() async throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent(
            "SchneeBar-profile-logical-identity-tests-\(UUID().uuidString)",
            isDirectory: true
        )
    defer { try? FileManager.default.removeItem(at: directory) }

    let fileURL = directory.appendingPathComponent(
        "connections.json",
        isDirectory: false
    )
    let store = ApplicationSupportGitHubConnectionProfileStore(
        fileURL: fileURL
    )

    let original = try logicalIdentityProfile(
        connectionID: UUID(
            uuidString: "10000000-0000-0000-0000-000000000001"
        )!,
        login: "octocat",
        createdAt: Date(timeIntervalSince1970: 1_000)
    )
    let duplicate = try logicalIdentityProfile(
        connectionID: UUID(
            uuidString: "10000000-0000-0000-0000-000000000002"
        )!,
        login: "renamed-octocat",
        createdAt: Date(timeIntervalSince1970: 2_000)
    )

    try await store.save(original)
    let persistedBefore = try Data(contentsOf: fileURL)

    await #expect(throws: GitHubConnectionProfileStoreError.self) {
        try await store.save(duplicate)
    }

    #expect(try Data(contentsOf: fileURL) == persistedBefore)
    #expect(try await store.loadAll() == [original])
}

private func logicalIdentityProfile(
    connectionID: UUID,
    login: String,
    createdAt: Date
) throws -> GitHubConnectionProfile {
    GitHubConnectionProfile(
        connection: GitHubConnection(
            id: connectionID,
            displayName: "Personal GitHub",
            deploymentKind: .githubDotCom,
            webBaseURL: try #require(
                URL(string: "https://github.com")
            ),
            apiVersion: "2026-03-10"
        ),
        account: GitHubAccountIdentity(
            id: "42",
            login: login
        ),
        authenticationMethod: .deviceFlow,
        clientID: "Iv1.public-client",
        repositorySelection: .allAccessible,
        isEnabled: true,
        createdAt: createdAt,
        lastConnectedAt: createdAt
    )
}

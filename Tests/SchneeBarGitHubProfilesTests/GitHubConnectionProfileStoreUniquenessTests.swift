import Foundation
import SchneeBarGitHub
import SchneeBarGitHubProfiles
import Testing

@Test
func profileStoreRejectsDifferentUUIDForSameEndpointAndStableAccount() async throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent(
            "SchneeBar-profile-uniqueness-tests-\(UUID().uuidString)",
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

    let original = try uniquenessProfile(
        id: UUID(
            uuidString: "20000000-0000-0000-0000-000000000001"
        )!
    )
    let duplicate = try uniquenessProfile(
        id: UUID(
            uuidString: "20000000-0000-0000-0000-000000000002"
        )!
    )

    try await store.save(original)

    await #expect(
        throws: GitHubConnectionProfileStoreError.self
    ) {
        try await store.save(duplicate)
    }

    #expect(try await store.loadAll() == [original])
}

private func uniquenessProfile(
    id: UUID
) throws -> GitHubConnectionProfile {
    let connection = GitHubConnection(
        id: id,
        displayName: "GitHub.com",
        deploymentKind: .githubDotCom,
        webBaseURL: try #require(
            URL(string: "https://github.com")
        ),
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

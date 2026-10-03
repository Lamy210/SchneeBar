import Foundation
import SchneeBarGitHub
import SchneeBarGitHubProfiles
import Testing

@Test
func profileStoreRejectsDifferentUUIDForSameEndpointAndAccount() async throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent(
            "SchneeBar-profile-identity-tests-\(UUID().uuidString)",
            isDirectory: true
        )
    defer { try? FileManager.default.removeItem(at: directory) }

    let store = ApplicationSupportGitHubConnectionProfileStore(
        fileURL: directory.appendingPathComponent(
            "connections.json",
            isDirectory: false
        )
    )
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

    try await store.save(first)

    do {
        try await store.save(duplicate)
        Issue.record(
            "Expected the store to reject a duplicate logical GitHub identity"
        )
    } catch {
        // Any rejection proves the missing identity invariant before the
        // production error contract is introduced.
    }

    #expect(try await store.loadAll() == [first])
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

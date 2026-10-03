import Foundation
import SchneeBarGitHub
import SchneeBarGitHubProfiles
import Testing

@Test
func savingDuplicateAccountEndpointWithDifferentConnectionIDIsRejected() async throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent(
            "SchneeBar-profile-identity-tests-\(UUID().uuidString)",
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

    let existing = try identityProfile(
        connectionID: UUID(
            uuidString: "21000000-0000-0000-0000-000000000001"
        )!,
        webBaseURL: "https://github.com",
        login: "octocat"
    )
    let duplicate = try identityProfile(
        connectionID: UUID(
            uuidString: "21000000-0000-0000-0000-000000000002"
        )!,
        webBaseURL: "https://github.com:443",
        login: "renamed-octocat"
    )

    try await store.save(existing)

    await #expect(throws: GitHubConnectionProfileStoreError.self) {
        try await store.save(duplicate)
    }

    #expect(try await store.loadAll() == [existing])
}

private func identityProfile(
    connectionID: UUID,
    webBaseURL: String,
    login: String
) throws -> GitHubConnectionProfile {
    let connection = GitHubConnection(
        id: connectionID,
        displayName: "Personal GitHub",
        deploymentKind: .githubDotCom,
        webBaseURL: try #require(URL(string: webBaseURL)),
        serverVersion: nil,
        apiVersion: "2026-03-10"
    )

    return GitHubConnectionProfile(
        connection: connection,
        account: GitHubAccountIdentity(
            id: "42",
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

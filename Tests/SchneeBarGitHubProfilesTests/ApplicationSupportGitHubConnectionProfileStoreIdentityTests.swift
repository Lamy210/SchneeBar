import Foundation
import SchneeBarGitHub
import SchneeBarGitHubProfiles
import Testing

@Test
func savingDifferentUUIDForSameEndpointAndAccountIsRejected() async throws {
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
    let original = try identityProfile(
        connectionID: UUID(
            uuidString: "20000000-0000-0000-0000-000000000001"
        )!,
        endpoint: "https://github.com",
        login: "old-login"
    )
    let duplicate = try identityProfile(
        connectionID: UUID(
            uuidString: "20000000-0000-0000-0000-000000000002"
        )!,
        endpoint: "https://github.com:443",
        login: "new-login"
    )

    try await store.save(original)

    await #expect(
        throws: GitHubConnectionProfileStoreError.self
    ) {
        try await store.save(duplicate)
    }

    #expect(try await store.loadAll() == [original])
}

private func identityProfile(
    connectionID: UUID,
    endpoint: String,
    login: String
) throws -> GitHubConnectionProfile {
    GitHubConnectionProfile(
        connection: GitHubConnection(
            id: connectionID,
            displayName: "GitHub",
            deploymentKind: .githubDotCom,
            webBaseURL: try #require(URL(string: endpoint))
        ),
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

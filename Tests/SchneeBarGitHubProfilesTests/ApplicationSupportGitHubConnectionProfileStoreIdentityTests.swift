import Foundation
import SchneeBarGitHub
import SchneeBarGitHubProfiles
import Testing

@Test
func savingDifferentUUIDForSameCanonicalEndpointAndAccountIsRejected() async throws {
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
    let existing = try profile(
        id: UUID(
            uuidString: "41000000-0000-0000-0000-000000000001"
        )!,
        webBaseURL: "https://github.com",
        login: "old-login"
    )
    let duplicate = try profile(
        id: UUID(
            uuidString: "41000000-0000-0000-0000-000000000002"
        )!,
        webBaseURL: "https://github.com:443",
        login: "renamed-login"
    )

    try await store.save(existing)

    var wasRejectedByProfileStore = false
    do {
        try await store.save(duplicate)
    } catch is GitHubConnectionProfileStoreError {
        wasRejectedByProfileStore = true
    }

    #expect(wasRejectedByProfileStore)
    #expect(try await store.loadAll() == [existing])
}

private func profile(
    id: UUID,
    webBaseURL: String,
    login: String
) throws -> GitHubConnectionProfile {
    GitHubConnectionProfile(
        connection: GitHubConnection(
            id: id,
            displayName: "GitHub.com",
            deploymentKind: .githubDotCom,
            webBaseURL: try #require(URL(string: webBaseURL)),
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
        createdAt: Date(timeIntervalSince1970: 1_000),
        lastConnectedAt: Date(timeIntervalSince1970: 1_500)
    )
}

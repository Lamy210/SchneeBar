import Foundation
import SchneeBarGitHub
import SchneeBarGitHubProfiles
import Testing

@Test
func profileStoreRejectsDifferentConnectionIDForSameEndpointAndAccount() async throws {
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
        id: UUID(
            uuidString: "61000000-0000-0000-0000-000000000001"
        )!,
        login: "octocat",
        webBaseURL: "https://github.com"
    )
    let duplicate = try identityProfile(
        id: UUID(
            uuidString: "61000000-0000-0000-0000-000000000002"
        )!,
        login: "renamed-octocat",
        webBaseURL: "https://github.com:443"
    )

    try await store.save(original)

    var rejectedDuplicate = false
    do {
        try await store.save(duplicate)
    } catch {
        rejectedDuplicate = true
    }

    #expect(rejectedDuplicate)
    #expect(try await store.loadAll() == [original])
}

private func identityProfile(
    id: UUID,
    login: String,
    webBaseURL: String
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

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

    do {
        try await context.store.save(duplicate)
        Issue.record("Expected duplicate connection identity to be rejected")
    } catch {
        // Any store rejection is sufficient for the red phase; the production
        // change will define the precise error contract.
    }

    #expect(try Data(contentsOf: context.fileURL) == before)
    #expect(try await context.store.loadAll() == [original])
}

private struct DuplicateIdentityStoreContext {
    let directory: URL
    let fileURL: URL
    let store: ApplicationSupportGitHubConnectionProfileStore
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

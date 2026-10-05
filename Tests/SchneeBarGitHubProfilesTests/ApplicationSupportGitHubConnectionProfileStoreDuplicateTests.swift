import Foundation
import SchneeBarGitHub
import SchneeBarGitHubProfiles
import Testing

@Test
func logicalDuplicateProfilesCollapseToOldestConnectionIdentity() async throws {
    let context = try duplicateProfileStore()
    defer { try? FileManager.default.removeItem(at: context.directory) }

    let oldest = try duplicateProfile(
        id: UUID(uuidString: "10000000-0000-0000-0000-000000000101")!,
        createdAt: Date(timeIntervalSince1970: 1_000),
        repositorySelection: .selected([101])
    )
    let newerDuplicate = try duplicateProfile(
        id: UUID(uuidString: "10000000-0000-0000-0000-000000000202")!,
        createdAt: Date(timeIntervalSince1970: 2_000),
        repositorySelection: .selected([202])
    )

    try await context.store.save(oldest)
    try await context.store.save(newerDuplicate)

    let profiles = try await context.store.loadAll()
    #expect(profiles == [oldest])
}

private struct DuplicateProfileStoreContext {
    let directory: URL
    let store: ApplicationSupportGitHubConnectionProfileStore
}

private func duplicateProfileStore() throws -> DuplicateProfileStoreContext {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent(
            "SchneeBar-profile-duplicate-tests-\(UUID().uuidString)",
            isDirectory: true
        )
    let fileURL = directory.appendingPathComponent(
        "connections.json",
        isDirectory: false
    )
    return DuplicateProfileStoreContext(
        directory: directory,
        store: ApplicationSupportGitHubConnectionProfileStore(fileURL: fileURL)
    )
}

private func duplicateProfile(
    id: UUID,
    createdAt: Date,
    repositorySelection: GitHubRepositoryMonitoringSelection
) throws -> GitHubConnectionProfile {
    let connection = GitHubConnection(
        id: id,
        displayName: "Personal GitHub",
        deploymentKind: .githubDotCom,
        webBaseURL: try #require(URL(string: "https://github.com")),
        serverVersion: nil,
        apiVersion: "2026-03-10"
    )
    return GitHubConnectionProfile(
        connection: connection,
        account: GitHubAccountIdentity(id: "42", login: "octocat"),
        authenticationMethod: .deviceFlow,
        clientID: "Iv1.public-client",
        repositorySelection: repositorySelection,
        isEnabled: true,
        createdAt: createdAt,
        lastConnectedAt: createdAt
    )
}

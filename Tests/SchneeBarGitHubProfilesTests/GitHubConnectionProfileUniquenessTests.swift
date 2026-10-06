import Foundation
import SchneeBarGitHub
import SchneeBarGitHubProfiles
import Testing

@Test
func savingDuplicateLogicalAccountProfileIsRejected() async throws {
    let context = try uniquenessProfileStore()
    defer { try? FileManager.default.removeItem(at: context.directory) }

    let original = try uniquenessProfile(
        id: UUID(uuidString: "20000000-0000-0000-0000-000000000001")!,
        createdAt: Date(timeIntervalSince1970: 1_000)
    )
    let duplicate = try uniquenessProfile(
        id: UUID(uuidString: "20000000-0000-0000-0000-000000000002")!,
        createdAt: Date(timeIntervalSince1970: 2_000)
    )

    try await context.store.save(original)

    await #expect(throws: (any Error).self) {
        try await context.store.save(duplicate)
    }

    #expect(try await context.store.loadAll() == [original])
    #expect(try await context.store.load(id: duplicate.id) == nil)
}

private struct UniquenessProfileStoreContext {
    let directory: URL
    let store: ApplicationSupportGitHubConnectionProfileStore
}

private func uniquenessProfileStore() throws -> UniquenessProfileStoreContext {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent(
            "SchneeBar-profile-uniqueness-tests-\(UUID().uuidString)",
            isDirectory: true
        )
    let fileURL = directory.appendingPathComponent(
        "connections.json",
        isDirectory: false
    )
    return UniquenessProfileStoreContext(
        directory: directory,
        store: ApplicationSupportGitHubConnectionProfileStore(fileURL: fileURL)
    )
}

private func uniquenessProfile(
    id: UUID,
    createdAt: Date
) throws -> GitHubConnectionProfile {
    GitHubConnectionProfile(
        connection: GitHubConnection(
            id: id,
            displayName: "Personal GitHub",
            deploymentKind: .githubDotCom,
            webBaseURL: try #require(URL(string: "https://github.com"))
        ),
        account: GitHubAccountIdentity(
            id: "42",
            login: "octocat"
        ),
        authenticationMethod: .deviceFlow,
        clientID: "Iv1.public-client",
        repositorySelection: .allAccessible,
        isEnabled: true,
        createdAt: createdAt,
        lastConnectedAt: createdAt
    )
}

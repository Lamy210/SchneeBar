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

    let existingID = UUID(
        uuidString: "21000000-0000-0000-0000-000000000001"
    )!
    let duplicateID = UUID(
        uuidString: "21000000-0000-0000-0000-000000000002"
    )!
    let existing = try identityProfile(
        connectionID: existingID,
        webBaseURL: "https://github.com",
        accountID: "42",
        login: "octocat"
    )
    let duplicate = try identityProfile(
        connectionID: duplicateID,
        webBaseURL: "https://github.com:443",
        accountID: "42",
        login: "renamed-octocat"
    )

    try await store.save(existing)

    await #expect(
        throws: GitHubConnectionProfileStoreError.duplicateAccountEndpoint(
            existingConnectionID: existingID,
            attemptedConnectionID: duplicateID
        )
    ) {
        try await store.save(duplicate)
    }

    #expect(try await store.loadAll() == [existing])
}

@Test
func updatingExistingProfileCannotCollideWithAnotherLogicalProfile() async throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent(
            "SchneeBar-profile-update-identity-tests-\(UUID().uuidString)",
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

    let existingID = UUID(
        uuidString: "22000000-0000-0000-0000-000000000001"
    )!
    let updatedID = UUID(
        uuidString: "22000000-0000-0000-0000-000000000002"
    )!
    let existing = try identityProfile(
        connectionID: existingID,
        webBaseURL: "https://github.com",
        accountID: "42",
        login: "octocat"
    )
    let originalSecond = try identityProfile(
        connectionID: updatedID,
        webBaseURL: "https://github.com",
        accountID: "43",
        login: "second-account"
    )
    let collidingUpdate = try identityProfile(
        connectionID: updatedID,
        webBaseURL: "https://github.com:443",
        accountID: "42",
        login: "renamed-octocat"
    )

    try await store.save(existing)
    try await store.save(originalSecond)

    await #expect(
        throws: GitHubConnectionProfileStoreError.duplicateAccountEndpoint(
            existingConnectionID: existingID,
            attemptedConnectionID: updatedID
        )
    ) {
        try await store.save(collidingUpdate)
    }

    #expect(try await store.loadAll() == [existing, originalSecond])
}

private func identityProfile(
    connectionID: UUID,
    webBaseURL: String,
    accountID: String,
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

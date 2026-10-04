import Foundation
import SchneeBarGitHub
import SchneeBarGitHubProfiles
import Testing

@Test
func savingDuplicateCanonicalEndpointAndAccountIdentityIsRejected() async throws {
    let context = try duplicateIdentityProfileStore()
    defer { try? FileManager.default.removeItem(at: context.directory) }

    let original = try duplicateIdentityProfile(
        id: UUID(uuidString: "61000000-0000-0000-0000-000000000001")!,
        webBaseURL: "https://github.com",
        login: "octocat"
    )
    let duplicate = try duplicateIdentityProfile(
        id: UUID(uuidString: "61000000-0000-0000-0000-000000000002")!,
        webBaseURL: "https://github.com:443/",
        login: "renamed-octocat"
    )

    try await context.store.save(original)

    await #expect(
        throws: GitHubConnectionProfileStoreError.duplicateConnectionIdentity
    ) {
        try await context.store.save(duplicate)
    }

    #expect(try await context.store.loadAll() == [original])
}

@Test
func loadingPersistedDuplicateCanonicalEndpointAndAccountIdentityIsRejected() async throws {
    let context = try duplicateIdentityProfileStore()
    defer { try? FileManager.default.removeItem(at: context.directory) }

    let original = try duplicateIdentityProfile(
        id: UUID(uuidString: "62000000-0000-0000-0000-000000000001")!,
        webBaseURL: "https://github.com",
        login: "octocat"
    )
    let duplicate = try duplicateIdentityProfile(
        id: UUID(uuidString: "62000000-0000-0000-0000-000000000002")!,
        webBaseURL: "https://github.com:443/",
        login: "renamed-octocat"
    )
    try writeDuplicateIdentityPayload(
        [original, duplicate],
        to: context.fileURL
    )

    await #expect(
        throws: GitHubConnectionProfileStoreError.duplicateConnectionIdentity
    ) {
        try await context.store.loadAll()
    }
}

@Test
func sameEndpointDifferentStableAccountsRemainSupported() async throws {
    let context = try duplicateIdentityProfileStore()
    defer { try? FileManager.default.removeItem(at: context.directory) }

    let first = try duplicateIdentityProfile(
        id: UUID(uuidString: "63000000-0000-0000-0000-000000000001")!,
        webBaseURL: "https://github.com",
        accountID: "42",
        login: "octocat"
    )
    let second = try duplicateIdentityProfile(
        id: UUID(uuidString: "63000000-0000-0000-0000-000000000002")!,
        webBaseURL: "https://github.com:443/",
        accountID: "84",
        login: "hubot"
    )

    try await context.store.save(first)
    try await context.store.save(second)

    #expect(
        Set(try await context.store.loadAll().map(\.id))
            == Set([first.id, second.id])
    )
}

private struct DuplicateIdentityProfileStoreContext {
    let directory: URL
    let fileURL: URL
    let store: ApplicationSupportGitHubConnectionProfileStore
}

private func duplicateIdentityProfileStore() throws -> DuplicateIdentityProfileStoreContext {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent(
            "SchneeBar-profile-identity-tests-\(UUID().uuidString)",
            isDirectory: true
        )
    let fileURL = directory.appendingPathComponent(
        "connections.json",
        isDirectory: false
    )
    return DuplicateIdentityProfileStoreContext(
        directory: directory,
        fileURL: fileURL,
        store: ApplicationSupportGitHubConnectionProfileStore(
            fileURL: fileURL
        )
    )
}

private func duplicateIdentityProfile(
    id: UUID,
    webBaseURL: String,
    accountID: String = "42",
    login: String
) throws -> GitHubConnectionProfile {
    GitHubConnectionProfile(
        connection: GitHubConnection(
            id: id,
            displayName: "GitHub",
            deploymentKind: .githubDotCom,
            webBaseURL: try #require(URL(string: webBaseURL)),
            serverVersion: nil,
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

private func writeDuplicateIdentityPayload(
    _ profiles: [GitHubConnectionProfile],
    to fileURL: URL
) throws {
    try FileManager.default.createDirectory(
        at: fileURL.deletingLastPathComponent(),
        withIntermediateDirectories: true
    )

    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    let profileObjects = try profiles.map { profile in
        try JSONSerialization.jsonObject(
            with: encoder.encode(profile)
        )
    }
    let payload: [String: Any] = [
        "schemaVersion": 1,
        "profiles": profileObjects,
    ]
    let data = try JSONSerialization.data(
        withJSONObject: payload,
        options: [.sortedKeys]
    )
    try data.write(to: fileURL)
}

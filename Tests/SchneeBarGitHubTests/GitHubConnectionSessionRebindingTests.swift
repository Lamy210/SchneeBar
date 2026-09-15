import Foundation
import SchneeBarGitHub
import Testing

private actor RebindingCredentialStore: GitHubCredentialStore {
    private var values: [GitHubCredentialKey: GitHubCredential] = [:]

    func load(for key: GitHubCredentialKey) async throws -> GitHubCredential? {
        values[key]
    }

    func save(_ credential: GitHubCredential, for key: GitHubCredentialKey) async throws {
        values[key] = credential
    }

    func delete(for key: GitHubCredentialKey) async throws {
        values.removeValue(forKey: key)
    }

    func value(for key: GitHubCredentialKey) -> GitHubCredential? {
        values[key]
    }
}

@Test
func rebindEstablishedSessionMovesCredentialToExistingConnectionIdentity() async throws {
    let store = RebindingCredentialStore()
    let coordinator = GitHubConnectionSessionCoordinator(credentialStore: store)
    let temporaryConnection = try rebindingConnection(
        id: UUID(uuidString: "00000000-0000-0000-0000-000000000111")!
    )
    let existingConnection = try rebindingConnection(
        id: UUID(uuidString: "00000000-0000-0000-0000-000000000222")!
    )
    let identity = GitHubAccountIdentity(id: "42", login: "octocat")
    let temporaryKey = GitHubCredentialKey(
        connectionID: temporaryConnection.id,
        accountID: identity.id
    )
    let existingKey = GitHubCredentialKey(
        connectionID: existingConnection.id,
        accountID: identity.id
    )
    let credential = GitHubCredential(accessToken: "ghu_access")
    try await store.save(credential, for: temporaryKey)

    let account = GitHubAuthenticatedAccount(identity: identity)
    let inventory = GitHubAccessInventory(account: account, installations: [])
    let session = GitHubConnectionSession(
        connectionID: temporaryConnection.id,
        account: account,
        credentialKey: temporaryKey,
        inventory: inventory,
        capabilities: GitHubCapabilityEvaluator().evaluate(
            connection: temporaryConnection,
            inventory: inventory
        )
    )

    let rebound = try await coordinator.rebindEstablishedSession(
        session,
        from: temporaryConnection,
        to: existingConnection
    )

    #expect(rebound.connectionID == existingConnection.id)
    #expect(rebound.credentialKey == existingKey)
    #expect(await store.value(for: temporaryKey) == nil)
    #expect(await store.value(for: existingKey) == credential)
}

@Test
func disconnectingOneConnectionLeavesAnotherAccountsCredentialUntouched() async throws {
    let store = RebindingCredentialStore()
    let coordinator = GitHubConnectionSessionCoordinator(credentialStore: store)
    let connectionA = try rebindingConnection(
        id: UUID(uuidString: "00000000-0000-0000-0000-000000000111")!
    )
    let connectionB = try rebindingConnection(
        id: UUID(uuidString: "00000000-0000-0000-0000-000000000222")!
    )
    let accountA = GitHubAccountIdentity(id: "42", login: "octocat")
    let accountB = GitHubAccountIdentity(id: "99", login: "hubot")
    let keyA = GitHubCredentialKey(connectionID: connectionA.id, accountID: accountA.id)
    let keyB = GitHubCredentialKey(connectionID: connectionB.id, accountID: accountB.id)
    let credentialA = GitHubCredential(accessToken: "ghu_a")
    let credentialB = GitHubCredential(accessToken: "ghu_b")
    try await store.save(credentialA, for: keyA)
    try await store.save(credentialB, for: keyB)

    try await coordinator.disconnect(connection: connectionA, identity: accountA)

    #expect(await store.value(for: keyA) == nil)
    #expect(await store.value(for: keyB) == credentialB)
}

private func rebindingConnection(id: UUID) throws -> GitHubConnection {
    GitHubConnection(
        id: id,
        displayName: "GitHub.com",
        deploymentKind: .githubDotCom,
        webBaseURL: try #require(URL(string: "https://github.com"))
    )
}

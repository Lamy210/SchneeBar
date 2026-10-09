import Foundation
import SchneeBarGitHub
import Testing

private actor ReboundAccountCredentialStore: GitHubCredentialStore {
    private var values: [GitHubCredentialKey: GitHubCredential] = [:]

    func load(for key: GitHubCredentialKey) async throws -> GitHubCredential? {
        values[key]
    }

    func save(
        _ credential: GitHubCredential,
        for key: GitHubCredentialKey
    ) async throws {
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
func rebindUsesFreshInventoryAccountMetadataWhenStableIDMatches() async throws {
    let sourceConnection = try reboundAccountConnection(
        id: UUID(uuidString: "00000000-0000-0000-0000-000000000411")!,
        displayName: "Temporary GitHub"
    )
    let targetConnection = try reboundAccountConnection(
        id: UUID(uuidString: "00000000-0000-0000-0000-000000000422")!,
        displayName: "Existing GitHub"
    )
    let staleIdentity = GitHubAccountIdentity(id: "42", login: "old-login")
    let freshIdentity = GitHubAccountIdentity(id: "42", login: "renamed-login")
    let sourceKey = GitHubCredentialKey(
        connectionID: sourceConnection.id,
        accountID: staleIdentity.id
    )
    let targetKey = GitHubCredentialKey(
        connectionID: targetConnection.id,
        accountID: staleIdentity.id
    )
    let credential = GitHubCredential(accessToken: "ghu_rebound")
    let store = ReboundAccountCredentialStore()
    try await store.save(credential, for: sourceKey)

    let staleAccount = GitHubAuthenticatedAccount(identity: staleIdentity)
    let freshAccount = GitHubAuthenticatedAccount(identity: freshIdentity)
    let inventory = GitHubAccessInventory(
        account: freshAccount,
        installations: []
    )
    let session = GitHubConnectionSession(
        connectionID: sourceConnection.id,
        account: staleAccount,
        credentialKey: sourceKey,
        inventory: inventory,
        capabilities: GitHubCapabilityEvaluator().evaluate(
            connection: sourceConnection,
            inventory: inventory
        )
    )
    let coordinator = GitHubConnectionSessionCoordinator(
        credentialStore: store
    )

    let result = try await coordinator.rebindEstablishedSession(
        session,
        from: sourceConnection,
        to: targetConnection
    )

    #expect(result.connectionID == targetConnection.id)
    #expect(result.account.identity.id == staleIdentity.id)
    #expect(result.account.identity.login == freshIdentity.login)
    #expect(result.inventory.account.identity == result.account.identity)
    #expect(result.credentialKey == targetKey)
    #expect(await store.value(for: sourceKey) == nil)
    #expect(await store.value(for: targetKey) == credential)
}

private func reboundAccountConnection(
    id: UUID,
    displayName: String
) throws -> GitHubConnection {
    GitHubConnection(
        id: id,
        displayName: displayName,
        deploymentKind: .githubDotCom,
        webBaseURL: try #require(URL(string: "https://github.com"))
    )
}

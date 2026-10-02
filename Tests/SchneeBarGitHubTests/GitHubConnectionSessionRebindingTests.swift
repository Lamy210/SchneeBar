import Foundation
import SchneeBarGitHub
import Testing

private actor RebindingLoadGate {
    private var isStarted = false
    private var isReleased = false
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseWaiters: [CheckedContinuation<Void, Never>] = []

    func markStartedAndWaitForRelease() async {
        if !isStarted {
            isStarted = true
            let waiters = startWaiters
            startWaiters.removeAll()
            for waiter in waiters {
                waiter.resume()
            }
        }
        if isReleased {
            return
        }
        await withCheckedContinuation { continuation in
            releaseWaiters.append(continuation)
        }
    }

    func waitUntilStarted() async {
        if isStarted {
            return
        }
        await withCheckedContinuation { continuation in
            startWaiters.append(continuation)
        }
    }

    func release() {
        guard !isReleased else { return }
        isReleased = true
        let waiters = releaseWaiters
        releaseWaiters.removeAll()
        for waiter in waiters {
            waiter.resume()
        }
    }
}

private actor CancellationRebindingCredentialStore: GitHubCredentialStore {
    private var values: [GitHubCredentialKey: GitHubCredential]
    private let blockedLoadKey: GitHubCredentialKey
    private let gate = RebindingLoadGate()

    init(
        values: [GitHubCredentialKey: GitHubCredential],
        blockedLoadKey: GitHubCredentialKey
    ) {
        self.values = values
        self.blockedLoadKey = blockedLoadKey
    }

    func load(for key: GitHubCredentialKey) async throws -> GitHubCredential? {
        if key == blockedLoadKey {
            await gate.markStartedAndWaitForRelease()
        }
        return values[key]
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

    func waitUntilBlockedLoadStarts() async {
        await gate.waitUntilStarted()
    }

    func releaseBlockedLoad() async {
        await gate.release()
    }

    func value(for key: GitHubCredentialKey) -> GitHubCredential? {
        values[key]
    }
}

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
func rebindEstablishedGHESSessionPreservesEndpointBinding() async throws {
    let store = RebindingCredentialStore()
    let coordinator = GitHubConnectionSessionCoordinator(
        credentialStore: store
    )
    let sourceConnection = GitHubConnection(
        id: UUID(
            uuidString:
                "00000000-0000-0000-0000-000000000311"
        )!,
        displayName: "Temporary GHES",
        deploymentKind: .enterpriseServer,
        webBaseURL: try #require(
            URL(string: "https://github.internal.example")
        )
    )
    let targetConnection = GitHubConnection(
        id: UUID(
            uuidString:
                "00000000-0000-0000-0000-000000000322"
        )!,
        displayName: "Existing GHES",
        deploymentKind: .enterpriseServer,
        webBaseURL: try #require(
            URL(string: "https://github.internal.example:443")
        )
    )
    let identity = GitHubAccountIdentity(
        id: "42",
        login: "octocat"
    )
    let sourceKey = GitHubCredentialKey(
        connectionID: sourceConnection.id,
        accountID: identity.id
    )
    let targetKey = GitHubCredentialKey(
        connectionID: targetConnection.id,
        accountID: identity.id
    )
    let credential = GitHubCredential(
        accessToken: "ghes-access",
        endpointIdentity: "https://github.internal.example"
    )
    try await store.save(credential, for: sourceKey)

    let account = GitHubAuthenticatedAccount(identity: identity)
    let inventory = GitHubAccessInventory(
        account: account,
        installations: []
    )
    let session = GitHubConnectionSession(
        connectionID: sourceConnection.id,
        account: account,
        credentialKey: sourceKey,
        inventory: inventory,
        capabilities: GitHubCapabilityEvaluator().evaluate(
            connection: sourceConnection,
            inventory: inventory
        )
    )

    let rebound = try await coordinator.rebindEstablishedSession(
        session,
        from: sourceConnection,
        to: targetConnection
    )

    #expect(rebound.credentialKey == targetKey)
    #expect(await store.value(for: sourceKey) == nil)
    #expect(await store.value(for: targetKey) == credential)
}

@Test
func cancelledRebindStopsBeforeCredentialMutation() async throws {
    let sourceConnection = try rebindingConnection(
        id: UUID(uuidString: "00000000-0000-0000-0000-000000000511")!
    )
    let targetConnection = try rebindingConnection(
        id: UUID(uuidString: "00000000-0000-0000-0000-000000000522")!
    )
    let identity = GitHubAccountIdentity(id: "42", login: "octocat")
    let sourceKey = GitHubCredentialKey(
        connectionID: sourceConnection.id,
        accountID: identity.id
    )
    let targetKey = GitHubCredentialKey(
        connectionID: targetConnection.id,
        accountID: identity.id
    )
    let sourceCredential = GitHubCredential(
        accessToken: "fresh-source-token",
        endpointIdentity: "https://github.com"
    )
    let existingTargetCredential = GitHubCredential(
        accessToken: "existing-target-token",
        endpointIdentity: "https://github.com"
    )
    let store = CancellationRebindingCredentialStore(
        values: [
            sourceKey: sourceCredential,
            targetKey: existingTargetCredential,
        ],
        blockedLoadKey: targetKey
    )
    let coordinator = GitHubConnectionSessionCoordinator(
        credentialStore: store
    )
    let account = GitHubAuthenticatedAccount(identity: identity)
    let inventory = GitHubAccessInventory(
        account: account,
        installations: []
    )
    let session = GitHubConnectionSession(
        connectionID: sourceConnection.id,
        account: account,
        credentialKey: sourceKey,
        inventory: inventory,
        capabilities: GitHubCapabilityEvaluator().evaluate(
            connection: sourceConnection,
            inventory: inventory
        )
    )

    let task = Task {
        try await coordinator.rebindEstablishedSession(
            session,
            from: sourceConnection,
            to: targetConnection
        )
    }

    await store.waitUntilBlockedLoadStarts()
    task.cancel()
    await store.releaseBlockedLoad()

    await #expect(throws: CancellationError.self) {
        try await task.value
    }
    #expect(await store.value(for: sourceKey) == sourceCredential)
    #expect(
        await store.value(for: targetKey)
            == existingTargetCredential
    )
}

@Test
func rebindEstablishedSessionRejectsMismatchedInventoryIdentityWithoutMovingCredential() async throws {
    let store = RebindingCredentialStore()
    let coordinator = GitHubConnectionSessionCoordinator(
        credentialStore: store
    )
    let sourceConnection = try rebindingConnection(
        id: UUID(uuidString: "00000000-0000-0000-0000-000000000111")!
    )
    let targetConnection = try rebindingConnection(
        id: UUID(uuidString: "00000000-0000-0000-0000-000000000222")!
    )
    let account = GitHubAuthenticatedAccount(
        identity: GitHubAccountIdentity(
            id: "42",
            login: "octocat"
        )
    )
    let inventoryAccount = GitHubAuthenticatedAccount(
        identity: GitHubAccountIdentity(
            id: "99",
            login: "other-user"
        )
    )
    let sourceKey = GitHubCredentialKey(
        connectionID: sourceConnection.id,
        accountID: account.identity.id
    )
    let targetKey = GitHubCredentialKey(
        connectionID: targetConnection.id,
        accountID: account.identity.id
    )
    let credential = GitHubCredential(accessToken: "ghu_access")
    try await store.save(credential, for: sourceKey)

    let inventory = GitHubAccessInventory(
        account: inventoryAccount,
        installations: []
    )
    let session = GitHubConnectionSession(
        connectionID: sourceConnection.id,
        account: account,
        credentialKey: sourceKey,
        inventory: inventory,
        capabilities: GitHubCapabilityEvaluator().evaluate(
            connection: sourceConnection,
            inventory: inventory
        )
    )

    await #expect(
        throws: GitHubConnectionSessionError.accountMismatch(
            expectedID: "42",
            actualID: "99"
        )
    ) {
        _ = try await coordinator.rebindEstablishedSession(
            session,
            from: sourceConnection,
            to: targetConnection
        )
    }

    #expect(await store.value(for: sourceKey) == credential)
    #expect(await store.value(for: targetKey) == nil)
}

@Test
func rebindEstablishedSessionRejectsDifferentEndpointsWithoutMovingCredential() async throws {
    let store = RebindingCredentialStore()
    let coordinator = GitHubConnectionSessionCoordinator(credentialStore: store)
    let sourceConnection = try rebindingConnection(
        id: UUID(uuidString: "00000000-0000-0000-0000-000000000111")!
    )
    let targetConnection = GitHubConnection(
        id: UUID(uuidString: "00000000-0000-0000-0000-000000000222")!,
        displayName: "Enterprise",
        deploymentKind: .enterpriseServer,
        webBaseURL: try #require(URL(string: "https://github.enterprise.example"))
    )
    let identity = GitHubAccountIdentity(id: "42", login: "octocat")
    let sourceKey = GitHubCredentialKey(
        connectionID: sourceConnection.id,
        accountID: identity.id
    )
    let targetKey = GitHubCredentialKey(
        connectionID: targetConnection.id,
        accountID: identity.id
    )
    let credential = GitHubCredential(accessToken: "ghu_access")
    try await store.save(credential, for: sourceKey)

    let account = GitHubAuthenticatedAccount(identity: identity)
    let inventory = GitHubAccessInventory(account: account, installations: [])
    let session = GitHubConnectionSession(
        connectionID: sourceConnection.id,
        account: account,
        credentialKey: sourceKey,
        inventory: inventory,
        capabilities: GitHubCapabilityEvaluator().evaluate(
            connection: sourceConnection,
            inventory: inventory
        )
    )

    await #expect(throws: GitHubConnectionSessionError.connectionEndpointMismatch) {
        _ = try await coordinator.rebindEstablishedSession(
            session,
            from: sourceConnection,
            to: targetConnection
        )
    }

    #expect(await store.value(for: sourceKey) == credential)
    #expect(await store.value(for: targetKey) == nil)
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

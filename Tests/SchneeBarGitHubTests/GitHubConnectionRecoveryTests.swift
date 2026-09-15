import Foundation
import SchneeBarGitHub
import Testing

private actor RecoveryCredentialStore: GitHubCredentialStore {
    private var values: [GitHubCredentialKey: GitHubCredential] = [:]
    private var saveCount = 0
    private var deleteCount = 0

    func load(for key: GitHubCredentialKey) async throws -> GitHubCredential? {
        values[key]
    }

    func save(_ credential: GitHubCredential, for key: GitHubCredentialKey) async throws {
        values[key] = credential
        saveCount += 1
    }

    func delete(for key: GitHubCredentialKey) async throws {
        values.removeValue(forKey: key)
        deleteCount += 1
    }

    func credential(for key: GitHubCredentialKey) -> GitHubCredential? {
        values[key]
    }

    func saves() -> Int {
        saveCount
    }

    func deletes() -> Int {
        deleteCount
    }
}

private enum RecoveryStubResponse: Sendable {
    case http(String, statusCode: Int = 200)
    case failure(URLError)
}

private actor RecoveryQueueTransport: GitHubHTTPTransport {
    private var responses: [RecoveryStubResponse]
    private var requests: [URLRequest] = []

    init(_ responses: [RecoveryStubResponse]) {
        self.responses = responses
    }

    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        requests.append(request)
        let response = responses.isEmpty
            ? RecoveryStubResponse.http("{}", statusCode: 500)
            : responses.removeFirst()

        switch response {
        case let .http(json, statusCode):
            let httpResponse = try #require(
                HTTPURLResponse(
                    url: request.url!,
                    statusCode: statusCode,
                    httpVersion: "HTTP/1.1",
                    headerFields: nil
                )
            )
            return (Data(json.utf8), httpResponse)
        case let .failure(error):
            throw error
        }
    }

    func recordedRequests() -> [URLRequest] {
        requests
    }
}

private let recoveryNow = Date(timeIntervalSince1970: 20_000)

@Test
func recoverMatchingAccountValidatesBeforeReplacingCredential() async throws {
    let transport = RecoveryQueueTransport([
        .http(recoveryUserJSON(id: 42, login: "octocat-renamed")),
        .http(recoveryUserJSON(id: 42, login: "octocat-renamed")),
        .http(#"{"total_count":0,"installations":[]}"#),
    ])
    let store = RecoveryCredentialStore()
    let connection = try recoveryConnection()
    let expected = GitHubAccountIdentity(id: "42", login: "octocat")
    let key = GitHubCredentialKey(connectionID: connection.id, accountID: expected.id)
    let oldCredential = GitHubCredential(accessToken: "old-token")
    let recoveryCredential = GitHubCredential(accessToken: "fresh-token")
    try await store.save(oldCredential, for: key)
    let baselineSaves = await store.saves()
    let coordinator = recoveryCoordinator(transport: transport, store: store)

    let session = try await coordinator.recover(
        connection: connection,
        expectedIdentity: expected,
        credential: recoveryCredential
    )

    #expect(session.connectionID == connection.id)
    #expect(session.account.identity.id == expected.id)
    #expect(session.account.identity.login == "octocat-renamed")
    #expect(session.credentialKey == key)
    #expect(await store.credential(for: key) == recoveryCredential)
    #expect(await store.saves() == baselineSaves + 1)
    #expect(await store.deletes() == 0)
}

@Test
func recoverRejectsDifferentAccountWithoutMutatingCredentialStore() async throws {
    let transport = RecoveryQueueTransport([
        .http(recoveryUserJSON(id: 99, login: "other-user")),
    ])
    let store = RecoveryCredentialStore()
    let connection = try recoveryConnection()
    let expected = GitHubAccountIdentity(id: "42", login: "octocat")
    let key = GitHubCredentialKey(connectionID: connection.id, accountID: expected.id)
    let oldCredential = GitHubCredential(accessToken: "old-token")
    try await store.save(oldCredential, for: key)
    let baselineSaves = await store.saves()
    let coordinator = recoveryCoordinator(transport: transport, store: store)

    await #expect(
        throws: GitHubConnectionSessionError.accountMismatch(
            expectedID: "42",
            actualID: "99"
        )
    ) {
        try await coordinator.recover(
            connection: connection,
            expectedIdentity: expected,
            credential: GitHubCredential(accessToken: "wrong-account-token")
        )
    }

    #expect(await store.credential(for: key) == oldCredential)
    #expect(await store.saves() == baselineSaves)
    #expect(await store.deletes() == 0)
}

@Test
func recoverMapsAccountLookup401WithoutReplacingCredential() async throws {
    let transport = RecoveryQueueTransport([
        .http(#"{"message":"Bad credentials"}"#, statusCode: 401),
    ])
    let store = RecoveryCredentialStore()
    let connection = try recoveryConnection()
    let expected = GitHubAccountIdentity(id: "42", login: "octocat")
    let key = GitHubCredentialKey(connectionID: connection.id, accountID: expected.id)
    let oldCredential = GitHubCredential(accessToken: "old-token")
    try await store.save(oldCredential, for: key)
    let baselineSaves = await store.saves()
    let coordinator = recoveryCoordinator(transport: transport, store: store)

    await #expect(throws: GitHubConnectionSessionError.reauthenticationRequired) {
        try await coordinator.recover(
            connection: connection,
            expectedIdentity: expected,
            credential: GitHubCredential(accessToken: "rejected-token")
        )
    }

    #expect(await store.credential(for: key) == oldCredential)
    #expect(await store.saves() == baselineSaves)
}

@Test
func recoverMapsInventory401WithoutReplacingCredential() async throws {
    let transport = RecoveryQueueTransport([
        .http(recoveryUserJSON(id: 42, login: "octocat")),
        .http(#"{"message":"Bad credentials"}"#, statusCode: 401),
    ])
    let store = RecoveryCredentialStore()
    let connection = try recoveryConnection()
    let expected = GitHubAccountIdentity(id: "42", login: "octocat")
    let key = GitHubCredentialKey(connectionID: connection.id, accountID: expected.id)
    let oldCredential = GitHubCredential(accessToken: "old-token")
    try await store.save(oldCredential, for: key)
    let baselineSaves = await store.saves()
    let coordinator = recoveryCoordinator(transport: transport, store: store)

    await #expect(throws: GitHubConnectionSessionError.reauthenticationRequired) {
        try await coordinator.recover(
            connection: connection,
            expectedIdentity: expected,
            credential: GitHubCredential(accessToken: "fresh-token")
        )
    }

    #expect(await store.credential(for: key) == oldCredential)
    #expect(await store.saves() == baselineSaves)
}

@Test
func recoverLeavesStoredCredentialUntouchedOnInventoryNetworkFailure() async throws {
    let transport = RecoveryQueueTransport([
        .http(recoveryUserJSON(id: 42, login: "octocat")),
        .failure(URLError(.notConnectedToInternet)),
    ])
    let store = RecoveryCredentialStore()
    let connection = try recoveryConnection()
    let expected = GitHubAccountIdentity(id: "42", login: "octocat")
    let key = GitHubCredentialKey(connectionID: connection.id, accountID: expected.id)
    let oldCredential = GitHubCredential(accessToken: "old-token")
    try await store.save(oldCredential, for: key)
    let baselineSaves = await store.saves()
    let coordinator = recoveryCoordinator(transport: transport, store: store)

    await #expect(throws: URLError.self) {
        try await coordinator.recover(
            connection: connection,
            expectedIdentity: expected,
            credential: GitHubCredential(accessToken: "fresh-token")
        )
    }

    #expect(await store.credential(for: key) == oldCredential)
    #expect(await store.saves() == baselineSaves)
}

@Test
func recoverOneAccountDoesNotMutateAnotherAccountOnSameEndpoint() async throws {
    let transport = RecoveryQueueTransport([
        .http(recoveryUserJSON(id: 42, login: "account-a")),
        .http(recoveryUserJSON(id: 42, login: "account-a")),
        .http(#"{"total_count":0,"installations":[]}"#),
    ])
    let store = RecoveryCredentialStore()
    let connection = try recoveryConnection()
    let accountA = GitHubAccountIdentity(id: "42", login: "account-a")
    let accountB = GitHubAccountIdentity(id: "99", login: "account-b")
    let accountAKey = GitHubCredentialKey(connectionID: connection.id, accountID: accountA.id)
    let accountBKey = GitHubCredentialKey(connectionID: connection.id, accountID: accountB.id)
    let accountAOld = GitHubCredential(accessToken: "account-a-old")
    let accountANew = GitHubCredential(accessToken: "account-a-new")
    let accountBOld = GitHubCredential(accessToken: "account-b-old")
    try await store.save(accountAOld, for: accountAKey)
    try await store.save(accountBOld, for: accountBKey)
    let coordinator = recoveryCoordinator(transport: transport, store: store)

    _ = try await coordinator.recover(
        connection: connection,
        expectedIdentity: accountA,
        credential: accountANew
    )

    #expect(await store.credential(for: accountAKey) == accountANew)
    #expect(await store.credential(for: accountBKey) == accountBOld)
}

private func recoveryCoordinator(
    transport: RecoveryQueueTransport,
    store: RecoveryCredentialStore
) -> GitHubConnectionSessionCoordinator {
    GitHubConnectionSessionCoordinator(
        credentialStore: store,
        accessClient: GitHubAccessClient(transport: transport),
        deviceFlowClient: GitHubDeviceFlowClient(
            transport: transport,
            now: { recoveryNow }
        ),
        now: { recoveryNow },
        refreshLeeway: 300
    )
}

private func recoveryConnection() throws -> GitHubConnection {
    GitHubConnection(
        id: UUID(uuidString: "00000000-0000-0000-0000-000000000142")!,
        displayName: "GitHub.com",
        deploymentKind: .githubDotCom,
        webBaseURL: try #require(URL(string: "https://github.com"))
    )
}

private func recoveryUserJSON(id: Int, login: String) -> String {
    #"{"id":\#(id),"login":"\#(login)","name":null,"avatar_url":null}"#
}

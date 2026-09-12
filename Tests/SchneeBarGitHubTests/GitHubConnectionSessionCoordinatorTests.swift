import Foundation
import SchneeBarGitHub
import Testing

private actor MemoryGitHubCredentialStore: GitHubCredentialStore {
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

private struct SessionStubResponse: Sendable {
    let json: String
    let statusCode: Int

    init(_ json: String, statusCode: Int = 200) {
        self.json = json
        self.statusCode = statusCode
    }
}

private actor SessionQueueTransport: GitHubHTTPTransport {
    private var responses: [SessionStubResponse]
    private var requests: [URLRequest] = []

    init(_ responses: [SessionStubResponse]) {
        self.responses = responses
    }

    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        requests.append(request)
        let response = responses.isEmpty
            ? SessionStubResponse("{}", statusCode: 500)
            : responses.removeFirst()
        let httpResponse = try #require(
            HTTPURLResponse(
                url: request.url!,
                statusCode: response.statusCode,
                httpVersion: "HTTP/1.1",
                headerFields: nil
            )
        )
        return (Data(response.json.utf8), httpResponse)
    }

    func recordedRequests() -> [URLRequest] {
        requests
    }
}

private let sessionNow = Date(timeIntervalSince1970: 10_000)

@Test
func establishValidatesIdentityBeforePersistingCredential() async throws {
    let transport = SessionQueueTransport([
        SessionStubResponse(userJSON(id: 42, login: "octocat")),
        SessionStubResponse(userJSON(id: 42, login: "octocat")),
        SessionStubResponse(#"{"total_count":0,"installations":[]}"#),
    ])
    let store = MemoryGitHubCredentialStore()
    let coordinator = makeCoordinator(transport: transport, store: store)
    let connection = try sessionConnection()
    let credential = GitHubCredential(accessToken: "ghu_access")

    let session = try await coordinator.establish(
        connection: connection,
        credential: credential
    )

    #expect(session.account.identity.id == "42")
    #expect(session.account.identity.login == "octocat")
    #expect(session.inventory.installations.isEmpty)
    #expect(session.credentialKey.accountID == "42")
    #expect(await store.credential(for: session.credentialKey) == credential)
    #expect(await store.saves() == 1)
}

@Test
func establishDoesNotPersistCredentialWhenIdentityValidationFails() async throws {
    let transport = SessionQueueTransport([
        SessionStubResponse(#"{"message":"Bad credentials"}"#, statusCode: 401)
    ])
    let store = MemoryGitHubCredentialStore()
    let coordinator = makeCoordinator(transport: transport, store: store)

    await #expect(throws: GitHubAccessClientError.httpStatus(401)) {
        try await coordinator.establish(
            connection: try sessionConnection(),
            credential: GitHubCredential(accessToken: "bad")
        )
    }

    #expect(await store.saves() == 0)
}

@Test
func restoreUsesNonExpiringStoredCredentialWithoutRefresh() async throws {
    let transport = SessionQueueTransport([
        SessionStubResponse(userJSON(id: 42, login: "octocat")),
        SessionStubResponse(userJSON(id: 42, login: "octocat")),
        SessionStubResponse(#"{"total_count":0,"installations":[]}"#),
    ])
    let store = MemoryGitHubCredentialStore()
    let connection = try sessionConnection()
    let identity = GitHubAccountIdentity(id: "42", login: "octocat")
    let key = GitHubCredentialKey(connectionID: connection.id, accountID: identity.id)
    try await store.save(GitHubCredential(accessToken: "pat_or_nonexpiring"), for: key)
    let initialSaveCount = await store.saves()
    let coordinator = makeCoordinator(transport: transport, store: store)

    let session = try await coordinator.restore(
        connection: connection,
        identity: identity
    )

    #expect(session.account.identity == identity)
    #expect(await store.saves() == initialSaveCount)
    let requests = await transport.recordedRequests()
    #expect(requests.allSatisfy { $0.httpMethod == "GET" })
}

@Test
func restoreRefreshesExpiringDeviceFlowCredentialAndPersistsRotation() async throws {
    let transport = SessionQueueTransport([
        SessionStubResponse(
            #"{"access_token":"ghu_new","expires_in":28800,"refresh_token":"ghr_new","refresh_token_expires_in":15897600,"token_type":"bearer"}"#
        ),
        SessionStubResponse(userJSON(id: 42, login: "octocat")),
        SessionStubResponse(userJSON(id: 42, login: "octocat")),
        SessionStubResponse(#"{"total_count":0,"installations":[]}"#),
    ])
    let store = MemoryGitHubCredentialStore()
    let connection = try sessionConnection()
    let identity = GitHubAccountIdentity(id: "42", login: "octocat")
    let key = GitHubCredentialKey(connectionID: connection.id, accountID: identity.id)
    try await store.save(
        GitHubCredential(
            accessToken: "ghu_old",
            refreshToken: "ghr_old",
            accessTokenExpiresAt: sessionNow.addingTimeInterval(120),
            refreshTokenExpiresAt: sessionNow.addingTimeInterval(10_000)
        ),
        for: key
    )
    let coordinator = makeCoordinator(transport: transport, store: store)

    _ = try await coordinator.restore(
        connection: connection,
        identity: identity,
        clientID: "Iv1.client"
    )

    let stored = try #require(await store.credential(for: key))
    #expect(stored.accessToken == "ghu_new")
    #expect(stored.refreshToken == "ghr_new")

    let requests = await transport.recordedRequests()
    #expect(requests.first?.httpMethod == "POST")
    let body = String(data: try #require(requests.first?.httpBody), encoding: .utf8) ?? ""
    #expect(body.contains("grant_type=refresh_token"))
    #expect(!body.contains("client_secret"))
}

@Test
func restoreRequiresReauthenticationWhenRefreshTokenIsExpired() async throws {
    let transport = SessionQueueTransport([])
    let store = MemoryGitHubCredentialStore()
    let connection = try sessionConnection()
    let identity = GitHubAccountIdentity(id: "42", login: "octocat")
    let key = GitHubCredentialKey(connectionID: connection.id, accountID: identity.id)
    try await store.save(
        GitHubCredential(
            accessToken: "ghu_old",
            refreshToken: "ghr_old",
            accessTokenExpiresAt: sessionNow.addingTimeInterval(120),
            refreshTokenExpiresAt: sessionNow.addingTimeInterval(120)
        ),
        for: key
    )
    let coordinator = makeCoordinator(transport: transport, store: store)

    await #expect(throws: GitHubConnectionSessionError.reauthenticationRequired) {
        try await coordinator.restore(
            connection: connection,
            identity: identity,
            clientID: "Iv1.client"
        )
    }

    #expect(await transport.recordedRequests().isEmpty)
}

@Test
func restoreRequiresReauthenticationWhenExpiringCredentialHasNoClientID() async throws {
    let transport = SessionQueueTransport([])
    let store = MemoryGitHubCredentialStore()
    let connection = try sessionConnection()
    let identity = GitHubAccountIdentity(id: "42", login: "octocat")
    let key = GitHubCredentialKey(connectionID: connection.id, accountID: identity.id)
    try await store.save(
        GitHubCredential(
            accessToken: "ghu_old",
            refreshToken: "ghr_old",
            accessTokenExpiresAt: sessionNow.addingTimeInterval(120),
            refreshTokenExpiresAt: sessionNow.addingTimeInterval(10_000)
        ),
        for: key
    )
    let coordinator = makeCoordinator(transport: transport, store: store)

    await #expect(throws: GitHubConnectionSessionError.reauthenticationRequired) {
        try await coordinator.restore(
            connection: connection,
            identity: identity
        )
    }
}

@Test
func restoreRejectsCredentialThatResolvesToAnotherAccount() async throws {
    let transport = SessionQueueTransport([
        SessionStubResponse(userJSON(id: 99, login: "other-user")),
    ])
    let store = MemoryGitHubCredentialStore()
    let connection = try sessionConnection()
    let identity = GitHubAccountIdentity(id: "42", login: "octocat")
    let key = GitHubCredentialKey(connectionID: connection.id, accountID: identity.id)
    try await store.save(GitHubCredential(accessToken: "ghu_wrong_account"), for: key)
    let coordinator = makeCoordinator(transport: transport, store: store)

    await #expect(
        throws: GitHubConnectionSessionError.accountMismatch(
            expectedID: "42",
            actualID: "99"
        )
    ) {
        try await coordinator.restore(
            connection: connection,
            identity: identity
        )
    }
}

@Test
func restoreFailsWhenCredentialIsMissing() async throws {
    let transport = SessionQueueTransport([])
    let store = MemoryGitHubCredentialStore()
    let coordinator = makeCoordinator(transport: transport, store: store)

    await #expect(throws: GitHubConnectionSessionError.credentialNotFound) {
        try await coordinator.restore(
            connection: try sessionConnection(),
            identity: GitHubAccountIdentity(id: "42", login: "octocat")
        )
    }

    #expect(await transport.recordedRequests().isEmpty)
}

@Test
func disconnectDeletesStoredCredential() async throws {
    let transport = SessionQueueTransport([])
    let store = MemoryGitHubCredentialStore()
    let connection = try sessionConnection()
    let identity = GitHubAccountIdentity(id: "42", login: "octocat")
    let key = GitHubCredentialKey(connectionID: connection.id, accountID: identity.id)
    try await store.save(GitHubCredential(accessToken: "ghu_access"), for: key)
    let coordinator = makeCoordinator(transport: transport, store: store)

    try await coordinator.disconnect(connection: connection, identity: identity)

    #expect(await store.credential(for: key) == nil)
    #expect(await store.deletes() == 1)
}

private func makeCoordinator(
    transport: SessionQueueTransport,
    store: MemoryGitHubCredentialStore
) -> GitHubConnectionSessionCoordinator {
    GitHubConnectionSessionCoordinator(
        credentialStore: store,
        accessClient: GitHubAccessClient(transport: transport),
        deviceFlowClient: GitHubDeviceFlowClient(
            transport: transport,
            now: { sessionNow }
        ),
        now: { sessionNow },
        refreshLeeway: 300
    )
}

private func sessionConnection() throws -> GitHubConnection {
    GitHubConnection(
        id: UUID(uuidString: "00000000-0000-0000-0000-000000000042")!,
        displayName: "GitHub.com",
        deploymentKind: .githubDotCom,
        webBaseURL: try #require(URL(string: "https://github.com"))
    )
}

private func userJSON(id: Int, login: String) -> String {
    #"{"id":\#(id),"login":"\#(login)","name":null,"avatar_url":null}"#
}

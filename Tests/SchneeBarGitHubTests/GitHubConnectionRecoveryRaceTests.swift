import Foundation
import SchneeBarGitHub
import Testing

private actor RecoveryRaceCredentialStore: GitHubCredentialStore {
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

    func credential(for key: GitHubCredentialKey) -> GitHubCredential? {
        values[key]
    }
}

private actor RecoveryRaceGate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        if isOpen {
            return
        }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    func open() {
        guard !isOpen else { return }
        isOpen = true
        let continuations = waiters
        waiters.removeAll()
        for continuation in continuations {
            continuation.resume()
        }
    }
}

private actor RecoveryRaceTransport: GitHubHTTPTransport {
    private let refreshStarted = RecoveryRaceGate()
    private let refreshRelease = RecoveryRaceGate()
    private let refreshCancelled = RecoveryRaceGate()
    private let recoveryValidationCompleted = RecoveryRaceGate()
    private var preReleaseUserRequestCount = 0

    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let method = request.httpMethod ?? "GET"
        let path = request.url?.path ?? ""

        if method == "POST" {
            await refreshStarted.open()
            await withTaskCancellationHandler {
                await refreshRelease.wait()
            } onCancel: {
                Task {
                    await self.refreshCancelled.open()
                }
            }
            return try response(
                request: request,
                json: #"{"access_token":"test-refreshed-old-token","expires_in":28800,"refresh_token":"test-refreshed-old-refresh","refresh_token_expires_in":15897600,"token_type":"bearer"}"#
            )
        }

        if path == "/user" {
            preReleaseUserRequestCount += 1
            return try response(
                request: request,
                json: recoveryRaceUserJSON(id: 42, login: "octocat")
            )
        }

        if path == "/user/installations" {
            if preReleaseUserRequestCount >= 2 {
                await recoveryValidationCompleted.open()
            }
            return try response(
                request: request,
                json: #"{"total_count":0,"installations":[]}"#
            )
        }

        return try response(
            request: request,
            json: #"{"message":"Not Found"}"#,
            statusCode: 404
        )
    }

    func waitUntilRefreshStarted() async {
        await refreshStarted.wait()
    }

    func waitUntilRefreshCancelled() async {
        await refreshCancelled.wait()
    }

    func waitUntilRecoveryValidationCompleted() async {
        await recoveryValidationCompleted.wait()
    }

    func releaseRefresh() async {
        await refreshRelease.open()
    }

    private func response(
        request: URLRequest,
        json: String,
        statusCode: Int = 200
    ) throws -> (Data, HTTPURLResponse) {
        let httpResponse = try #require(
            HTTPURLResponse(
                url: request.url!,
                statusCode: statusCode,
                httpVersion: "HTTP/1.1",
                headerFields: nil
            )
        )
        return (Data(json.utf8), httpResponse)
    }
}

private let recoveryRaceNow = Date(timeIntervalSince1970: 30_000)

@Test
func recoveryDrainsOlderRefreshBeforeSavingRecoveryCredential() async throws {
    let transport = RecoveryRaceTransport()
    let store = RecoveryRaceCredentialStore()
    let connection = try recoveryRaceConnection()
    let identity = GitHubAccountIdentity(id: "42", login: "octocat")
    let key = GitHubCredentialKey(connectionID: connection.id, accountID: identity.id)
    try await store.save(recoveryRaceExpiringCredential(), for: key)
    let coordinator = recoveryRaceCoordinator(transport: transport, store: store)
    let recoveryCredential = GitHubCredential(accessToken: "test-recovery-token")

    let restoreTask = Task {
        try await coordinator.restore(
            connection: connection,
            identity: identity,
            clientID: "test-client-id"
        )
    }
    await transport.waitUntilRefreshStarted()

    let recoveryTask = Task {
        try await coordinator.recover(
            connection: connection,
            expectedIdentity: identity,
            credential: recoveryCredential
        )
    }

    await transport.waitUntilRecoveryValidationCompleted()
    await transport.waitUntilRefreshCancelled()
    await transport.releaseRefresh()

    _ = try await recoveryTask.value
    _ = try await restoreTask.value

    #expect(await store.credential(for: key) == recoveryCredential)
}

@Test
func cancellingRecoveryDuringRefreshDrainPreventsRecoveryCredentialSave() async throws {
    let transport = RecoveryRaceTransport()
    let store = RecoveryRaceCredentialStore()
    let connection = try recoveryRaceConnection()
    let identity = GitHubAccountIdentity(id: "42", login: "octocat")
    let key = GitHubCredentialKey(connectionID: connection.id, accountID: identity.id)
    try await store.save(recoveryRaceExpiringCredential(), for: key)
    let coordinator = recoveryRaceCoordinator(transport: transport, store: store)
    let recoveryCredential = GitHubCredential(accessToken: "test-recovery-token")

    let restoreTask = Task {
        try await coordinator.restore(
            connection: connection,
            identity: identity,
            clientID: "test-client-id"
        )
    }
    await transport.waitUntilRefreshStarted()

    let recoveryTask = Task {
        try await coordinator.recover(
            connection: connection,
            expectedIdentity: identity,
            credential: recoveryCredential
        )
    }

    await transport.waitUntilRecoveryValidationCompleted()
    await transport.waitUntilRefreshCancelled()
    recoveryTask.cancel()
    await transport.releaseRefresh()

    await #expect(throws: CancellationError.self) {
        try await recoveryTask.value
    }
    _ = try await restoreTask.value

    let stored = try #require(await store.credential(for: key))
    #expect(stored.accessToken == "test-refreshed-old-token")
    #expect(stored != recoveryCredential)
}

private func recoveryRaceCoordinator(
    transport: RecoveryRaceTransport,
    store: RecoveryRaceCredentialStore
) -> GitHubConnectionSessionCoordinator {
    GitHubConnectionSessionCoordinator(
        credentialStore: store,
        accessClient: GitHubAccessClient(transport: transport),
        deviceFlowClient: GitHubDeviceFlowClient(
            transport: transport,
            now: { recoveryRaceNow }
        ),
        now: { recoveryRaceNow },
        refreshLeeway: 300
    )
}

private func recoveryRaceConnection() throws -> GitHubConnection {
    GitHubConnection(
        id: UUID(uuidString: "00000000-0000-0000-0000-000000000242")!,
        displayName: "GitHub.com",
        deploymentKind: .githubDotCom,
        webBaseURL: try #require(URL(string: "https://github.com"))
    )
}

private func recoveryRaceExpiringCredential() -> GitHubCredential {
    GitHubCredential(
        accessToken: "test-old-token",
        refreshToken: "test-old-refresh",
        accessTokenExpiresAt: recoveryRaceNow.addingTimeInterval(120),
        refreshTokenExpiresAt: recoveryRaceNow.addingTimeInterval(10_000)
    )
}

private func recoveryRaceUserJSON(id: Int, login: String) -> String {
    #"{"id":\#(id),"login":"\#(login)","name":null,"avatar_url":null}"#
}

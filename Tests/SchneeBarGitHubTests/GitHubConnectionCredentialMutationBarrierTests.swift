import Foundation
import SchneeBarGitHub
import Testing

private actor CredentialMutationGate {
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

private actor CredentialMutationBarrierStore: GitHubCredentialStore {
    private var values: [GitHubCredentialKey: GitHubCredential]
    private var shouldBlockNextLoad = true
    private let loadStarted = CredentialMutationGate()
    private let loadRelease = CredentialMutationGate()

    init(
        key: GitHubCredentialKey,
        credential: GitHubCredential
    ) {
        values = [key: credential]
    }

    func load(
        for key: GitHubCredentialKey
    ) async throws -> GitHubCredential? {
        let snapshot = values[key]
        if shouldBlockNextLoad {
            shouldBlockNextLoad = false
            await loadStarted.open()
            await loadRelease.wait()
        }
        return snapshot
    }

    func save(
        _ credential: GitHubCredential,
        for key: GitHubCredentialKey
    ) async throws {
        values[key] = credential
    }

    func delete(
        for key: GitHubCredentialKey
    ) async throws {
        values.removeValue(forKey: key)
    }

    func waitUntilLoadStarts() async {
        await loadStarted.wait()
    }

    func releaseLoad() async {
        await loadRelease.open()
    }

    func value(
        for key: GitHubCredentialKey
    ) -> GitHubCredential? {
        values[key]
    }
}

private actor CredentialMutationBarrierTransport: GitHubHTTPTransport {
    private var requests: [URLRequest] = []

    func data(
        for request: URLRequest
    ) async throws -> (Data, HTTPURLResponse) {
        requests.append(request)
        let response = try #require(
            HTTPURLResponse(
                url: request.url!,
                statusCode: 500,
                httpVersion: "HTTP/1.1",
                headerFields: nil
            )
        )
        return (
            Data(#"{"message":"unexpected request"}"#.utf8),
            response
        )
    }

    func requestCount() -> Int {
        requests.count
    }
}

private let credentialMutationNow = Date(
    timeIntervalSince1970: 80_000
)

@Test
func disconnectInvalidatesCredentialReadSuspendedBeforeMutation() async throws {
    let connection = GitHubConnection(
        id: UUID(
            uuidString: "00000000-0000-0000-0000-000000000942"
        )!,
        displayName: "GitHub.com",
        deploymentKind: .githubDotCom,
        webBaseURL: try #require(
            URL(string: "https://github.com")
        )
    )
    let identity = GitHubAccountIdentity(
        id: "42",
        login: "octocat"
    )
    let key = GitHubCredentialKey(
        connectionID: connection.id,
        accountID: identity.id
    )
    let credential = GitHubCredential(
        accessToken: "stale-access",
        refreshToken: "stale-refresh",
        accessTokenExpiresAt:
            credentialMutationNow.addingTimeInterval(120),
        refreshTokenExpiresAt:
            credentialMutationNow.addingTimeInterval(10_000),
        endpointIdentity: "https://github.com"
    )
    let store = CredentialMutationBarrierStore(
        key: key,
        credential: credential
    )
    let transport = CredentialMutationBarrierTransport()
    let coordinator = GitHubConnectionSessionCoordinator(
        credentialStore: store,
        accessClient: GitHubAccessClient(transport: transport),
        deviceFlowClient: GitHubDeviceFlowClient(
            transport: transport,
            now: { credentialMutationNow }
        ),
        now: { credentialMutationNow },
        refreshLeeway: 300
    )

    let restoreTask = Task {
        try await coordinator.restore(
            connection: connection,
            identity: identity,
            clientID: "test-client-id"
        )
    }
    await store.waitUntilLoadStarts()

    try await coordinator.disconnect(
        connection: connection,
        identity: identity
    )
    #expect(await store.value(for: key) == nil)

    await store.releaseLoad()

    await #expect(
        throws: GitHubConnectionSessionError.credentialNotFound
    ) {
        try await restoreTask.value
    }

    #expect(await store.value(for: key) == nil)
    #expect(await transport.requestCount() == 0)
}

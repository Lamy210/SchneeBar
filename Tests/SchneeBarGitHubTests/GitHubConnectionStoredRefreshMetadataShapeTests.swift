import Foundation
import SchneeBarGitHub
import Testing

private actor StoredRefreshShapeStore: GitHubCredentialStore {
    private var values: [GitHubCredentialKey: GitHubCredential]

    init(
        key: GitHubCredentialKey,
        credential: GitHubCredential
    ) {
        values = [key: credential]
    }

    func load(
        for key: GitHubCredentialKey
    ) async throws -> GitHubCredential? {
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
}

private actor StoredRefreshShapeTransport: GitHubHTTPTransport {
    private var requestCountValue = 0

    func data(
        for request: URLRequest
    ) async throws -> (Data, HTTPURLResponse) {
        requestCountValue += 1
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
        requestCountValue
    }
}

@Test
func restoreRejectsStoredOrphanRefreshExpiryBeforeNetwork() async throws {
    let now = Date(timeIntervalSince1970: 203_000)
    let connection = GitHubConnection(
        id: UUID(
            uuidString: "00000000-0000-0000-0000-000000002730"
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
        accessToken: "stored_access",
        refreshToken: nil,
        accessTokenExpiresAt: now.addingTimeInterval(3_600),
        refreshTokenExpiresAt: now.addingTimeInterval(7_200),
        endpointIdentity: "https://github.com"
    )
    let store = StoredRefreshShapeStore(
        key: key,
        credential: credential
    )
    let transport = StoredRefreshShapeTransport()
    let coordinator = GitHubConnectionSessionCoordinator(
        credentialStore: store,
        accessClient: GitHubAccessClient(transport: transport),
        deviceFlowClient: GitHubDeviceFlowClient(
            transport: transport,
            now: { now }
        ),
        now: { now }
    )

    await #expect(
        throws: GitHubConnectionSessionError.reauthenticationRequired
    ) {
        try await coordinator.restore(
            connection: connection,
            identity: identity,
            clientID: "Iv1.public-client-id"
        )
    }

    #expect(await transport.requestCount() == 0)
}

@Test
func restoreRejectsEmptyStoredRefreshTokenBeforeNetwork() async throws {
    let now = Date(timeIntervalSince1970: 204_000)
    let connection = GitHubConnection(
        id: UUID(
            uuidString: "00000000-0000-0000-0000-000000002731"
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
        accessToken: "stored_access",
        refreshToken: "",
        accessTokenExpiresAt: now.addingTimeInterval(3_600),
        refreshTokenExpiresAt: now.addingTimeInterval(7_200),
        endpointIdentity: "https://github.com"
    )
    let store = StoredRefreshShapeStore(
        key: key,
        credential: credential
    )
    let transport = StoredRefreshShapeTransport()
    let coordinator = GitHubConnectionSessionCoordinator(
        credentialStore: store,
        accessClient: GitHubAccessClient(transport: transport),
        deviceFlowClient: GitHubDeviceFlowClient(
            transport: transport,
            now: { now }
        ),
        now: { now }
    )

    await #expect(
        throws: GitHubConnectionSessionError.reauthenticationRequired
    ) {
        try await coordinator.restore(
            connection: connection,
            identity: identity,
            clientID: "Iv1.public-client-id"
        )
    }

    #expect(await transport.requestCount() == 0)
}

@Test
func restoreRejectsStoredRefreshTokenWithoutExpiryWhileAccessTokenFreshBeforeNetwork() async throws {
    let now = Date(timeIntervalSince1970: 205_000)
    let connection = GitHubConnection(
        id: UUID(
            uuidString: "00000000-0000-0000-0000-000000002732"
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
        accessToken: "stored_access",
        refreshToken: "stored_refresh",
        accessTokenExpiresAt: now.addingTimeInterval(3_600),
        refreshTokenExpiresAt: nil,
        endpointIdentity: "https://github.com"
    )
    let store = StoredRefreshShapeStore(
        key: key,
        credential: credential
    )
    let transport = StoredRefreshShapeTransport()
    let coordinator = GitHubConnectionSessionCoordinator(
        credentialStore: store,
        accessClient: GitHubAccessClient(transport: transport),
        deviceFlowClient: GitHubDeviceFlowClient(
            transport: transport,
            now: { now }
        ),
        now: { now }
    )

    await #expect(
        throws: GitHubConnectionSessionError.reauthenticationRequired
    ) {
        try await coordinator.restore(
            connection: connection,
            identity: identity,
            clientID: "Iv1.public-client-id"
        )
    }

    #expect(await transport.requestCount() == 0)
}

import Foundation
import SchneeBarGitHub
import Testing

private actor StoredAccessTokenCredentialStore: GitHubCredentialStore {
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

    func delete(
        for key: GitHubCredentialKey
    ) async throws {
        values.removeValue(forKey: key)
    }

    func value(
        for key: GitHubCredentialKey
    ) -> GitHubCredential? {
        values[key]
    }
}

private actor StoredAccessTokenTransport: GitHubHTTPTransport {
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

private actor StoredAccessTokenRefreshTransport: GitHubHTTPTransport {
    private var requests: [URLRequest] = []

    func data(
        for request: URLRequest
    ) async throws -> (Data, HTTPURLResponse) {
        requests.append(request)
        let response = try #require(
            HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: "HTTP/1.1",
                headerFields: nil
            )
        )
        return (
            Data(
                #"{"access_token":"refreshed_access","refresh_token":"refreshed_refresh","expires_in":28800,"refresh_token_expires_in":15811200,"token_type":"bearer","scope":""}"#.utf8
            ),
            response
        )
    }

    func requestCount() -> Int {
        requests.count
    }
}

private actor StoredAccessTokenAccessTransport: GitHubHTTPTransport {
    private var requests: [URLRequest] = []

    func data(
        for request: URLRequest
    ) async throws -> (Data, HTTPURLResponse) {
        requests.append(request)
        let path = request.url?.path ?? ""
        let json: String
        switch path {
        case "/user":
            json = #"{"id":42,"login":"octocat","name":null,"avatar_url":null}"#
        case "/user/installations":
            json = #"{"total_count":0,"installations":[]}"#
        default:
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

        let response = try #require(
            HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: "HTTP/1.1",
                headerFields: nil
            )
        )
        return (Data(json.utf8), response)
    }

    func recordedRequests() -> [URLRequest] {
        requests
    }
}

@Test
func restoreRejectsOversizedStoredAccessTokenBeforeNetwork() async throws {
    let connection = GitHubConnection(
        id: UUID(
            uuidString: "00000000-0000-0000-0000-000000002660"
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
    let oversizedAccessToken = String(
        repeating: "a",
        count: GitHubDeviceFlowResponsePolicy
            .maximumOpaqueTokenCharacters + 1
    )
    let store = StoredAccessTokenCredentialStore(
        key: key,
        credential: GitHubCredential(
            accessToken: oversizedAccessToken,
            endpointIdentity: "https://github.com"
        )
    )
    let transport = StoredAccessTokenTransport()
    let coordinator = GitHubConnectionSessionCoordinator(
        credentialStore: store,
        accessClient: GitHubAccessClient(
            transport: transport
        )
    )

    await #expect(
        throws: GitHubConnectionSessionError.reauthenticationRequired
    ) {
        try await coordinator.restore(
            connection: connection,
            identity: identity
        )
    }

    #expect(await transport.requestCount() == 0)
}

@Test
func restoreRefreshesOversizedExpiringStoredAccessTokenBeforeGitHubIO() async throws {
    let now = Date(timeIntervalSince1970: 90_000)
    let connection = GitHubConnection(
        id: UUID(
            uuidString: "00000000-0000-0000-0000-000000002661"
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
    let oversizedAccessToken = String(
        repeating: "a",
        count: GitHubDeviceFlowResponsePolicy
            .maximumOpaqueTokenCharacters + 1
    )
    let store = StoredAccessTokenCredentialStore(
        key: key,
        credential: GitHubCredential(
            accessToken: oversizedAccessToken,
            refreshToken: "stored_refresh",
            accessTokenExpiresAt: now.addingTimeInterval(30),
            refreshTokenExpiresAt: now.addingTimeInterval(3_600),
            endpointIdentity: "https://github.com"
        )
    )
    let refreshTransport = StoredAccessTokenRefreshTransport()
    let accessTransport = StoredAccessTokenAccessTransport()
    let coordinator = GitHubConnectionSessionCoordinator(
        credentialStore: store,
        accessClient: GitHubAccessClient(
            transport: accessTransport
        ),
        deviceFlowClient: GitHubDeviceFlowClient(
            transport: refreshTransport,
            now: { now }
        ),
        now: { now },
        refreshLeeway: 300
    )

    let session = try await coordinator.restore(
        connection: connection,
        identity: identity,
        clientID: "Iv1.public-client-id"
    )

    #expect(session.account.identity == identity)
    #expect(await refreshTransport.requestCount() == 1)

    let accessRequests = await accessTransport.recordedRequests()
    #expect(accessRequests.count == 3)
    #expect(
        accessRequests.allSatisfy {
            $0.value(forHTTPHeaderField: "Authorization")
                == "Bearer refreshed_access"
        }
    )

    let persisted = try #require(await store.value(for: key))
    #expect(persisted.accessToken == "refreshed_access")
    #expect(persisted.refreshToken == "refreshed_refresh")
}

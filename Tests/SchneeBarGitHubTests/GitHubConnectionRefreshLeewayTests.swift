import Foundation
import SchneeBarGitHub
import Testing

private actor RefreshLeewayCredentialStore: GitHubCredentialStore {
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
}

private struct RefreshLeewayStubResponse: Sendable {
    let json: String
    let statusCode: Int

    init(_ json: String, statusCode: Int = 200) {
        self.json = json
        self.statusCode = statusCode
    }
}

private actor RefreshLeewayTransport: GitHubHTTPTransport {
    private var responses: [RefreshLeewayStubResponse]
    private var requests: [URLRequest] = []

    init(_ responses: [RefreshLeewayStubResponse]) {
        self.responses = responses
    }

    func data(
        for request: URLRequest
    ) async throws -> (Data, HTTPURLResponse) {
        requests.append(request)
        let response = responses.isEmpty
            ? RefreshLeewayStubResponse(
                #"{"message":"unexpected request"}"#,
                statusCode: 500
            )
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

private let refreshLeewayNow = Date(timeIntervalSince1970: 20_000)

@Test
func infiniteRefreshLeewayDoesNotInvalidateFreshStoredCredential() async throws {
    let connection = GitHubConnection(
        id: UUID(
            uuidString: "00000000-0000-0000-0000-000000000094"
        )!,
        displayName: "GitHub.com",
        deploymentKind: .githubDotCom,
        webBaseURL: try #require(URL(string: "https://github.com"))
    )
    let identity = GitHubAccountIdentity(id: "42", login: "octocat")
    let key = GitHubCredentialKey(
        connectionID: connection.id,
        accountID: identity.id
    )
    let store = RefreshLeewayCredentialStore()
    try await store.save(
        GitHubCredential(
            accessToken: "fresh-access",
            refreshToken: "fresh-refresh",
            accessTokenExpiresAt:
                refreshLeewayNow.addingTimeInterval(3_600),
            refreshTokenExpiresAt:
                refreshLeewayNow.addingTimeInterval(10_000),
            endpointIdentity: "https://github.com"
        ),
        for: key
    )

    let transport = RefreshLeewayTransport([
        RefreshLeewayStubResponse(
            #"{"id":42,"login":"octocat","name":null,"avatar_url":null}"#
        ),
        RefreshLeewayStubResponse(
            #"{"id":42,"login":"octocat","name":null,"avatar_url":null}"#
        ),
        RefreshLeewayStubResponse(
            #"{"total_count":0,"installations":[]}"#
        ),
    ])
    let coordinator = GitHubConnectionSessionCoordinator(
        credentialStore: store,
        accessClient: GitHubAccessClient(transport: transport),
        deviceFlowClient: GitHubDeviceFlowClient(
            transport: transport,
            now: { refreshLeewayNow }
        ),
        now: { refreshLeewayNow },
        refreshLeeway: .infinity
    )

    let session = try await coordinator.restore(
        connection: connection,
        identity: identity
    )

    #expect(session.account.identity == identity)
    let requests = await transport.recordedRequests()
    #expect(requests.count == 3)
    #expect(requests.allSatisfy { $0.httpMethod == "GET" })
}

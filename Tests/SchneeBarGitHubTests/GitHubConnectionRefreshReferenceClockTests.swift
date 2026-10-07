import Foundation
import SchneeBarGitHub
import Testing

private final class RefreshReferenceSteppingClock: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [Date]
    private let fallback: Date

    init(values: [Date], fallback: Date) {
        self.values = values
        self.fallback = fallback
    }

    func now() -> Date {
        lock.lock()
        defer { lock.unlock() }
        guard !values.isEmpty else {
            return fallback
        }
        return values.removeFirst()
    }
}

private actor RefreshReferenceCredentialStore: GitHubCredentialStore {
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

private struct RefreshReferenceStubResponse: Sendable {
    let json: String
    let statusCode: Int

    init(_ json: String, statusCode: Int = 200) {
        self.json = json
        self.statusCode = statusCode
    }
}

private actor RefreshReferenceTransport: GitHubHTTPTransport {
    private var responses: [RefreshReferenceStubResponse]
    private var requests: [URLRequest] = []

    init(_ responses: [RefreshReferenceStubResponse]) {
        self.responses = responses
    }

    func data(
        for request: URLRequest
    ) async throws -> (Data, HTTPURLResponse) {
        requests.append(request)
        let response = responses.isEmpty
            ? RefreshReferenceStubResponse(
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

private let refreshReferenceNow = Date(timeIntervalSince1970: 30_000)

@Test
func refreshDecisionUsesOneReferenceClockInstant() async throws {
    let connection = GitHubConnection(
        id: UUID(
            uuidString: "00000000-0000-0000-0000-000000000098"
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
    let store = RefreshReferenceCredentialStore()
    try await store.save(
        GitHubCredential(
            accessToken: "old-access",
            refreshToken: "old-refresh",
            accessTokenExpiresAt:
                refreshReferenceNow.addingTimeInterval(30),
            refreshTokenExpiresAt:
                refreshReferenceNow.addingTimeInterval(1_000),
            endpointIdentity: "https://github.com"
        ),
        for: key
    )

    let transport = RefreshReferenceTransport([
        RefreshReferenceStubResponse(
            #"{"access_token":"new-access","expires_in":28800,"refresh_token":"new-refresh","refresh_token_expires_in":15897600,"token_type":"bearer"}"#
        ),
        RefreshReferenceStubResponse(
            #"{"id":42,"login":"octocat","name":null,"avatar_url":null}"#
        ),
        RefreshReferenceStubResponse(
            #"{"id":42,"login":"octocat","name":null,"avatar_url":null}"#
        ),
        RefreshReferenceStubResponse(
            #"{"total_count":0,"installations":[]}"#
        ),
    ])
    let clock = RefreshReferenceSteppingClock(
        values: [
            refreshReferenceNow,
            refreshReferenceNow,
            refreshReferenceNow,
            refreshReferenceNow.addingTimeInterval(800),
        ],
        fallback: refreshReferenceNow.addingTimeInterval(800)
    )
    let coordinator = GitHubConnectionSessionCoordinator(
        credentialStore: store,
        accessClient: GitHubAccessClient(transport: transport),
        deviceFlowClient: GitHubDeviceFlowClient(
            transport: transport,
            now: { refreshReferenceNow }
        ),
        now: { clock.now() },
        refreshLeeway: 300
    )

    let session = try await coordinator.restore(
        connection: connection,
        identity: identity,
        clientID: "Iv1.public-client-id"
    )

    #expect(session.account.identity == identity)
    let requests = await transport.recordedRequests()
    #expect(requests.count == 4)
    #expect(requests[0].httpMethod == "POST")
    #expect(requests.dropFirst().allSatisfy { $0.httpMethod == "GET" })
}

import Foundation
import SchneeBarGitHub
import Testing

private actor CandidateRefreshLifetimeStore: GitHubCredentialStore {
    private var values: [GitHubCredentialKey: GitHubCredential] = [:]

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
}

private actor CandidateRefreshLifetimeTransport: GitHubHTTPTransport {
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

private let candidateRefreshLifetimeNow = Date(
    timeIntervalSince1970: 40_000
)

@Test
func establishRejectsCandidateRefreshExpiryBeyondDefensiveLifetimeBeforeNetwork() async throws {
    let connection = try candidateRefreshLifetimeConnection(
        id: "00000000-0000-0000-0000-000000002790"
    )
    let transport = CandidateRefreshLifetimeTransport()
    let coordinator = GitHubConnectionSessionCoordinator(
        credentialStore: CandidateRefreshLifetimeStore(),
        accessClient: GitHubAccessClient(transport: transport),
        now: { candidateRefreshLifetimeNow }
    )

    await #expect(
        throws: GitHubConnectionSessionError.reauthenticationRequired
    ) {
        try await coordinator.establish(
            connection: connection,
            credential: overlongRefreshCandidateCredential()
        )
    }

    #expect(await transport.requestCount() == 0)
}

@Test
func recoverRejectsCandidateRefreshExpiryBeyondDefensiveLifetimeBeforeNetwork() async throws {
    let connection = try candidateRefreshLifetimeConnection(
        id: "00000000-0000-0000-0000-000000002791"
    )
    let transport = CandidateRefreshLifetimeTransport()
    let coordinator = GitHubConnectionSessionCoordinator(
        credentialStore: CandidateRefreshLifetimeStore(),
        accessClient: GitHubAccessClient(transport: transport),
        now: { candidateRefreshLifetimeNow }
    )

    await #expect(
        throws: GitHubConnectionSessionError.reauthenticationRequired
    ) {
        try await coordinator.recover(
            connection: connection,
            expectedIdentity: GitHubAccountIdentity(
                id: "42",
                login: "octocat"
            ),
            credential: overlongRefreshCandidateCredential()
        )
    }

    #expect(await transport.requestCount() == 0)
}

private func candidateRefreshLifetimeConnection(
    id: String
) throws -> GitHubConnection {
    GitHubConnection(
        id: try #require(UUID(uuidString: id)),
        displayName: "GitHub.com",
        deploymentKind: .githubDotCom,
        webBaseURL: try #require(
            URL(string: "https://github.com")
        )
    )
}

private func overlongRefreshCandidateCredential() -> GitHubCredential {
    GitHubCredential(
        accessToken: "candidate_access",
        refreshToken: "candidate_refresh",
        accessTokenExpiresAt:
            candidateRefreshLifetimeNow.addingTimeInterval(3_600),
        refreshTokenExpiresAt:
            candidateRefreshLifetimeNow.addingTimeInterval(
                TimeInterval(
                    GitHubDeviceFlowCredentialLifetimePolicy
                        .maximumRefreshTokenLifetime + 1
                )
            )
    )
}

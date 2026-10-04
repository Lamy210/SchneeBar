import Foundation
import SchneeBarGitHub
import Testing

private actor CandidateNonFiniteRefreshStore: GitHubCredentialStore {
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

private actor CandidateNonFiniteRefreshTransport: GitHubHTTPTransport {
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

private let candidateNonFiniteRefreshNow = Date(
    timeIntervalSince1970: 50_000
)

@Test
func establishRejectsInfiniteCandidateRefreshExpiryBeforeNetwork() async throws {
    let connection = try candidateNonFiniteRefreshConnection(
        id: "00000000-0000-0000-0000-000000002820"
    )
    let transport = CandidateNonFiniteRefreshTransport()
    let coordinator = GitHubConnectionSessionCoordinator(
        credentialStore: CandidateNonFiniteRefreshStore(),
        accessClient: GitHubAccessClient(transport: transport),
        now: { candidateNonFiniteRefreshNow }
    )

    await #expect(
        throws: GitHubConnectionSessionError.reauthenticationRequired
    ) {
        try await coordinator.establish(
            connection: connection,
            credential: nonFiniteRefreshCandidateCredential(
                expiry: Date(timeIntervalSince1970: .infinity)
            )
        )
    }

    #expect(await transport.requestCount() == 0)
}

@Test
func recoverRejectsNaNCandidateRefreshExpiryBeforeNetwork() async throws {
    let connection = try candidateNonFiniteRefreshConnection(
        id: "00000000-0000-0000-0000-000000002821"
    )
    let transport = CandidateNonFiniteRefreshTransport()
    let coordinator = GitHubConnectionSessionCoordinator(
        credentialStore: CandidateNonFiniteRefreshStore(),
        accessClient: GitHubAccessClient(transport: transport),
        now: { candidateNonFiniteRefreshNow }
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
            credential: nonFiniteRefreshCandidateCredential(
                expiry: Date(timeIntervalSince1970: .nan)
            )
        )
    }

    #expect(await transport.requestCount() == 0)
}

private func candidateNonFiniteRefreshConnection(
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

private func nonFiniteRefreshCandidateCredential(
    expiry: Date
) -> GitHubCredential {
    GitHubCredential(
        accessToken: "candidate_access",
        refreshToken: "candidate_refresh",
        accessTokenExpiresAt:
            candidateNonFiniteRefreshNow.addingTimeInterval(3_600),
        refreshTokenExpiresAt: expiry
    )
}

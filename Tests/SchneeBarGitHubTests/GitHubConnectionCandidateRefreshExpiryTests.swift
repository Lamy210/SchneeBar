import Foundation
import SchneeBarGitHub
import Testing

private actor CandidateExpiredRefreshStore: GitHubCredentialStore {
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

private actor CandidateExpiredRefreshTransport: GitHubHTTPTransport {
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

private let candidateExpiredRefreshNow = Date(
    timeIntervalSince1970: 50_000
)

@Test
func establishRejectsExpiredCandidateRefreshTokenBeforeNetwork() async throws {
    let connection = try candidateExpiredRefreshConnection(
        id: "00000000-0000-0000-0000-000000002810"
    )
    let transport = CandidateExpiredRefreshTransport()
    let coordinator = GitHubConnectionSessionCoordinator(
        credentialStore: CandidateExpiredRefreshStore(),
        accessClient: GitHubAccessClient(transport: transport),
        now: { candidateExpiredRefreshNow }
    )

    await #expect(
        throws: GitHubConnectionSessionError.reauthenticationRequired
    ) {
        try await coordinator.establish(
            connection: connection,
            credential: expiredRefreshCandidateCredential()
        )
    }

    #expect(await transport.requestCount() == 0)
}

@Test
func recoverRejectsExpiredCandidateRefreshTokenBeforeNetwork() async throws {
    let connection = try candidateExpiredRefreshConnection(
        id: "00000000-0000-0000-0000-000000002811"
    )
    let transport = CandidateExpiredRefreshTransport()
    let coordinator = GitHubConnectionSessionCoordinator(
        credentialStore: CandidateExpiredRefreshStore(),
        accessClient: GitHubAccessClient(transport: transport),
        now: { candidateExpiredRefreshNow }
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
            credential: expiredRefreshCandidateCredential()
        )
    }

    #expect(await transport.requestCount() == 0)
}

private func candidateExpiredRefreshConnection(
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

private func expiredRefreshCandidateCredential() -> GitHubCredential {
    GitHubCredential(
        accessToken: "candidate_access",
        refreshToken: "candidate_refresh",
        accessTokenExpiresAt:
            candidateExpiredRefreshNow.addingTimeInterval(3_600),
        refreshTokenExpiresAt:
            candidateExpiredRefreshNow.addingTimeInterval(-1)
    )
}

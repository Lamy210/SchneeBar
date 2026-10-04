import Foundation
import SchneeBarGitHub
import Testing

private actor CandidateOrphanRefreshStore: GitHubCredentialStore {
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

private actor CandidateOrphanRefreshTransport: GitHubHTTPTransport {
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

private let candidateOrphanRefreshNow = Date(
    timeIntervalSince1970: 60_000
)

@Test
func establishRejectsOrphanCandidateRefreshExpiryBeforeNetwork() async throws {
    let connection = try candidateOrphanRefreshConnection(
        id: "00000000-0000-0000-0000-000000002840"
    )
    let transport = CandidateOrphanRefreshTransport()
    let coordinator = GitHubConnectionSessionCoordinator(
        credentialStore: CandidateOrphanRefreshStore(),
        accessClient: GitHubAccessClient(transport: transport),
        now: { candidateOrphanRefreshNow }
    )

    await #expect(
        throws: GitHubConnectionSessionError.reauthenticationRequired
    ) {
        try await coordinator.establish(
            connection: connection,
            credential: orphanRefreshExpiryCandidateCredential()
        )
    }

    #expect(await transport.requestCount() == 0)
}

@Test
func recoverRejectsOrphanCandidateRefreshExpiryBeforeNetwork() async throws {
    let connection = try candidateOrphanRefreshConnection(
        id: "00000000-0000-0000-0000-000000002841"
    )
    let transport = CandidateOrphanRefreshTransport()
    let coordinator = GitHubConnectionSessionCoordinator(
        credentialStore: CandidateOrphanRefreshStore(),
        accessClient: GitHubAccessClient(transport: transport),
        now: { candidateOrphanRefreshNow }
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
            credential: orphanRefreshExpiryCandidateCredential()
        )
    }

    #expect(await transport.requestCount() == 0)
}

private func candidateOrphanRefreshConnection(
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

private func orphanRefreshExpiryCandidateCredential() -> GitHubCredential {
    GitHubCredential(
        accessToken: "candidate_access",
        refreshToken: nil,
        accessTokenExpiresAt:
            candidateOrphanRefreshNow.addingTimeInterval(3_600),
        refreshTokenExpiresAt:
            candidateOrphanRefreshNow.addingTimeInterval(86_400)
    )
}

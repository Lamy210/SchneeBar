import Foundation
import SchneeBarGitHub
import Testing

private actor CandidateEmptyRefreshTokenStore: GitHubCredentialStore {
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

private actor CandidateEmptyRefreshTokenTransport: GitHubHTTPTransport {
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

private let candidateEmptyRefreshTokenNow = Date(
    timeIntervalSince1970: 31_000
)

@Test
func establishRejectsEmptyCandidateRefreshTokenBeforeNetwork() async throws {
    let connection = try candidateEmptyRefreshTokenConnection(
        id: "00000000-0000-0000-0000-000000002850"
    )
    let transport = CandidateEmptyRefreshTokenTransport()
    let coordinator = GitHubConnectionSessionCoordinator(
        credentialStore: CandidateEmptyRefreshTokenStore(),
        accessClient: GitHubAccessClient(transport: transport),
        now: { candidateEmptyRefreshTokenNow }
    )

    await #expect(
        throws: GitHubConnectionSessionError.reauthenticationRequired
    ) {
        try await coordinator.establish(
            connection: connection,
            credential: emptyRefreshTokenCandidateCredential()
        )
    }

    #expect(await transport.requestCount() == 0)
}

@Test
func recoverRejectsEmptyCandidateRefreshTokenBeforeNetwork() async throws {
    let connection = try candidateEmptyRefreshTokenConnection(
        id: "00000000-0000-0000-0000-000000002851"
    )
    let transport = CandidateEmptyRefreshTokenTransport()
    let coordinator = GitHubConnectionSessionCoordinator(
        credentialStore: CandidateEmptyRefreshTokenStore(),
        accessClient: GitHubAccessClient(transport: transport),
        now: { candidateEmptyRefreshTokenNow }
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
            credential: emptyRefreshTokenCandidateCredential()
        )
    }

    #expect(await transport.requestCount() == 0)
}

private func candidateEmptyRefreshTokenConnection(
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

private func emptyRefreshTokenCandidateCredential() -> GitHubCredential {
    GitHubCredential(
        accessToken: "candidate_access",
        refreshToken: "",
        accessTokenExpiresAt:
            candidateEmptyRefreshTokenNow.addingTimeInterval(3_600),
        refreshTokenExpiresAt:
            candidateEmptyRefreshTokenNow.addingTimeInterval(7_200)
    )
}

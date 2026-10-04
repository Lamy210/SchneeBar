import Foundation
import SchneeBarGitHub
import Testing

private actor CandidateRefreshTokenStore: GitHubCredentialStore {
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

private actor CandidateRefreshTokenTransport: GitHubHTTPTransport {
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

private let candidateRefreshTokenNow = Date(
    timeIntervalSince1970: 60_000
)

@Test
func establishRejectsOversizedCandidateRefreshTokenBeforeNetwork() async throws {
    let connection = try candidateRefreshTokenConnection(
        id: "00000000-0000-0000-0000-000000002830"
    )
    let transport = CandidateRefreshTokenTransport()
    let coordinator = GitHubConnectionSessionCoordinator(
        credentialStore: CandidateRefreshTokenStore(),
        accessClient: GitHubAccessClient(transport: transport),
        now: { candidateRefreshTokenNow }
    )

    await #expect(
        throws: GitHubConnectionSessionError.reauthenticationRequired
    ) {
        try await coordinator.establish(
            connection: connection,
            credential: candidateRefreshCredential(
                refreshToken: String(
                    repeating: "r",
                    count: GitHubDeviceFlowResponsePolicy
                        .maximumOpaqueTokenCharacters + 1
                )
            )
        )
    }

    #expect(await transport.requestCount() == 0)
}

@Test
func recoverRejectsOversizedCandidateRefreshTokenBeforeNetwork() async throws {
    let connection = try candidateRefreshTokenConnection(
        id: "00000000-0000-0000-0000-000000002831"
    )
    let transport = CandidateRefreshTokenTransport()
    let coordinator = GitHubConnectionSessionCoordinator(
        credentialStore: CandidateRefreshTokenStore(),
        accessClient: GitHubAccessClient(transport: transport),
        now: { candidateRefreshTokenNow }
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
            credential: candidateRefreshCredential(
                refreshToken: String(
                    repeating: "r",
                    count: GitHubDeviceFlowResponsePolicy
                        .maximumOpaqueTokenCharacters + 1
                )
            )
        )
    }

    #expect(await transport.requestCount() == 0)
}

@Test
func establishRejectsEmptyCandidateRefreshTokenBeforeNetwork() async throws {
    let connection = try candidateRefreshTokenConnection(
        id: "00000000-0000-0000-0000-000000002832"
    )
    let transport = CandidateRefreshTokenTransport()
    let coordinator = GitHubConnectionSessionCoordinator(
        credentialStore: CandidateRefreshTokenStore(),
        accessClient: GitHubAccessClient(transport: transport),
        now: { candidateRefreshTokenNow }
    )

    await #expect(
        throws: GitHubConnectionSessionError.reauthenticationRequired
    ) {
        try await coordinator.establish(
            connection: connection,
            credential: candidateRefreshCredential(refreshToken: "")
        )
    }

    #expect(await transport.requestCount() == 0)
}

@Test
func recoverRejectsEmptyCandidateRefreshTokenBeforeNetwork() async throws {
    let connection = try candidateRefreshTokenConnection(
        id: "00000000-0000-0000-0000-000000002833"
    )
    let transport = CandidateRefreshTokenTransport()
    let coordinator = GitHubConnectionSessionCoordinator(
        credentialStore: CandidateRefreshTokenStore(),
        accessClient: GitHubAccessClient(transport: transport),
        now: { candidateRefreshTokenNow }
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
            credential: candidateRefreshCredential(refreshToken: "")
        )
    }

    #expect(await transport.requestCount() == 0)
}

private func candidateRefreshTokenConnection(
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

private func candidateRefreshCredential(
    refreshToken: String
) -> GitHubCredential {
    GitHubCredential(
        accessToken: "candidate_access",
        refreshToken: refreshToken,
        accessTokenExpiresAt:
            candidateRefreshTokenNow.addingTimeInterval(3_600),
        refreshTokenExpiresAt:
            candidateRefreshTokenNow.addingTimeInterval(86_400)
    )
}

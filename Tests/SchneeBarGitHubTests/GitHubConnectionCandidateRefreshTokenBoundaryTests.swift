import Foundation
import SchneeBarGitHub
import Testing

private actor CandidateRefreshTokenBoundaryStore: GitHubCredentialStore {
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

private actor CandidateRefreshTokenBoundaryTransport: GitHubHTTPTransport {
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

private let candidateRefreshTokenBoundaryNow = Date(
    timeIntervalSince1970: 32_000
)

@Test
func establishRejectsOversizedCandidateRefreshTokenBeforeNetwork() async throws {
    let connection = try candidateRefreshTokenBoundaryConnection(
        id: "00000000-0000-0000-0000-000000002870"
    )
    let transport = CandidateRefreshTokenBoundaryTransport()
    let coordinator = GitHubConnectionSessionCoordinator(
        credentialStore: CandidateRefreshTokenBoundaryStore(),
        accessClient: GitHubAccessClient(transport: transport),
        now: { candidateRefreshTokenBoundaryNow }
    )

    await #expect(
        throws: GitHubConnectionSessionError.reauthenticationRequired
    ) {
        try await coordinator.establish(
            connection: connection,
            credential: oversizedRefreshTokenCandidateCredential()
        )
    }

    #expect(await transport.requestCount() == 0)
}

@Test
func recoverRejectsOversizedCandidateRefreshTokenBeforeNetwork() async throws {
    let connection = try candidateRefreshTokenBoundaryConnection(
        id: "00000000-0000-0000-0000-000000002871"
    )
    let transport = CandidateRefreshTokenBoundaryTransport()
    let coordinator = GitHubConnectionSessionCoordinator(
        credentialStore: CandidateRefreshTokenBoundaryStore(),
        accessClient: GitHubAccessClient(transport: transport),
        now: { candidateRefreshTokenBoundaryNow }
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
            credential: oversizedRefreshTokenCandidateCredential()
        )
    }

    #expect(await transport.requestCount() == 0)
}

private func candidateRefreshTokenBoundaryConnection(
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

private func oversizedRefreshTokenCandidateCredential() -> GitHubCredential {
    GitHubCredential(
        accessToken: "candidate_access",
        refreshToken: String(
            repeating: "r",
            count:
                GitHubDeviceFlowResponsePolicy.maximumOpaqueTokenCharacters
                    + 1
        ),
        accessTokenExpiresAt:
            candidateRefreshTokenBoundaryNow.addingTimeInterval(3_600),
        refreshTokenExpiresAt:
            candidateRefreshTokenBoundaryNow.addingTimeInterval(7_200)
    )
}

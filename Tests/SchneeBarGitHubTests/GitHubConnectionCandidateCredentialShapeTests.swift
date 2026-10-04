import Foundation
import SchneeBarGitHub
import Testing

private actor CandidateCredentialShapeStore: GitHubCredentialStore {
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

private actor CandidateCredentialShapeTransport: GitHubHTTPTransport {
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

private let candidateCredentialShapeNow = Date(
    timeIntervalSince1970: 30_000
)

@Test
func establishRejectsCandidateMissingRefreshExpiryBeforeNetwork() async throws {
    let connection = try candidateCredentialShapeConnection(
        id: "00000000-0000-0000-0000-000000002780"
    )
    let transport = CandidateCredentialShapeTransport()
    let coordinator = GitHubConnectionSessionCoordinator(
        credentialStore: CandidateCredentialShapeStore(),
        accessClient: GitHubAccessClient(transport: transport),
        now: { candidateCredentialShapeNow }
    )

    await #expect(
        throws: GitHubConnectionSessionError.reauthenticationRequired
    ) {
        try await coordinator.establish(
            connection: connection,
            credential: incompleteExpiringCandidateCredential()
        )
    }

    #expect(await transport.requestCount() == 0)
}

@Test
func recoverRejectsCandidateMissingRefreshExpiryBeforeNetwork() async throws {
    let connection = try candidateCredentialShapeConnection(
        id: "00000000-0000-0000-0000-000000002781"
    )
    let transport = CandidateCredentialShapeTransport()
    let coordinator = GitHubConnectionSessionCoordinator(
        credentialStore: CandidateCredentialShapeStore(),
        accessClient: GitHubAccessClient(transport: transport),
        now: { candidateCredentialShapeNow }
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
            credential: incompleteExpiringCandidateCredential()
        )
    }

    #expect(await transport.requestCount() == 0)
}

private func candidateCredentialShapeConnection(
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

private func incompleteExpiringCandidateCredential() -> GitHubCredential {
    GitHubCredential(
        accessToken: "candidate_access",
        refreshToken: "candidate_refresh",
        accessTokenExpiresAt:
            candidateCredentialShapeNow.addingTimeInterval(3_600),
        refreshTokenExpiresAt: nil
    )
}

import Foundation
import SchneeBarGitHub
import Testing

private actor CandidateAccessTokenCredentialStore: GitHubCredentialStore {
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

private actor CandidateAccessTokenTransport: GitHubHTTPTransport {
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

@Test
func establishRejectsOversizedCandidateAccessTokenBeforeNetwork() async throws {
    let connection = try candidateAccessTokenConnection(
        id: "00000000-0000-0000-0000-000000002670"
    )
    let transport = CandidateAccessTokenTransport()
    let coordinator = GitHubConnectionSessionCoordinator(
        credentialStore: CandidateAccessTokenCredentialStore(),
        accessClient: GitHubAccessClient(transport: transport)
    )

    await #expect(
        throws: GitHubConnectionSessionError.reauthenticationRequired
    ) {
        try await coordinator.establish(
            connection: connection,
            credential: oversizedCandidateCredential()
        )
    }

    #expect(await transport.requestCount() == 0)
}

@Test
func recoverRejectsOversizedCandidateAccessTokenBeforeNetwork() async throws {
    let connection = try candidateAccessTokenConnection(
        id: "00000000-0000-0000-0000-000000002671"
    )
    let transport = CandidateAccessTokenTransport()
    let coordinator = GitHubConnectionSessionCoordinator(
        credentialStore: CandidateAccessTokenCredentialStore(),
        accessClient: GitHubAccessClient(transport: transport)
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
            credential: oversizedCandidateCredential()
        )
    }

    #expect(await transport.requestCount() == 0)
}

@Test
func establishRejectsCandidateAccessExpiryBeyondDefensiveLifetimeBeforeNetwork() async throws {
    let now = Date(timeIntervalSince1970: 210_000)
    let connection = try candidateAccessTokenConnection(
        id: "00000000-0000-0000-0000-000000002672"
    )
    let transport = CandidateAccessTokenTransport()
    let coordinator = GitHubConnectionSessionCoordinator(
        credentialStore: CandidateAccessTokenCredentialStore(),
        accessClient: GitHubAccessClient(transport: transport),
        now: { now }
    )

    await #expect(
        throws: GitHubConnectionSessionError.reauthenticationRequired
    ) {
        try await coordinator.establish(
            connection: connection,
            credential: overlongCandidateCredential(now: now)
        )
    }

    #expect(await transport.requestCount() == 0)
}

@Test
func recoverRejectsCandidateAccessExpiryBeyondDefensiveLifetimeBeforeNetwork() async throws {
    let now = Date(timeIntervalSince1970: 210_000)
    let connection = try candidateAccessTokenConnection(
        id: "00000000-0000-0000-0000-000000002673"
    )
    let transport = CandidateAccessTokenTransport()
    let coordinator = GitHubConnectionSessionCoordinator(
        credentialStore: CandidateAccessTokenCredentialStore(),
        accessClient: GitHubAccessClient(transport: transport),
        now: { now }
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
            credential: overlongCandidateCredential(now: now)
        )
    }

    #expect(await transport.requestCount() == 0)
}

private func candidateAccessTokenConnection(
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

private func oversizedCandidateCredential() -> GitHubCredential {
    GitHubCredential(
        accessToken: String(
            repeating: "a",
            count: GitHubDeviceFlowResponsePolicy
                .maximumOpaqueTokenCharacters + 1
        )
    )
}

private func overlongCandidateCredential(
    now: Date
) -> GitHubCredential {
    GitHubCredential(
        accessToken: "candidate_access",
        accessTokenExpiresAt: now.addingTimeInterval(
            TimeInterval(
                GitHubDeviceFlowCredentialLifetimePolicy
                    .maximumAccessTokenLifetime + 1
            )
        )
    )
}

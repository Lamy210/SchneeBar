import Foundation
import SchneeBarGitHub
import Testing

private actor TokenTypeTransport: GitHubHTTPTransport {
    private var responses: [String]

    init(_ responses: [String]) {
        self.responses = responses
    }

    func data(
        for request: URLRequest
    ) async throws -> (Data, HTTPURLResponse) {
        let payload = responses.isEmpty ? "{}" : responses.removeFirst()
        let response = try #require(
            HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: "HTTP/1.1",
                headerFields: nil
            )
        )
        return (Data(payload.utf8), response)
    }
}

private let tokenTypeNow = Date(timeIntervalSince1970: 1_000)

@Test
func issuedCredentialRejectsMissingAlternateOrWhitespaceTokenTypes() async throws {
    let invalidPayloads: [String] = [
        #"{"access_token":"ghu_access"}"#,
        #"{"access_token":"ghu_access","token_type":"mac"}"#,
        #"{"access_token":"ghu_access","token_type":" bearer"}"#,
        #"{"access_token":"ghu_access","token_type":"bearer "}"#,
    ]

    for payload in invalidPayloads {
        try await expectTokenTypePollFailure(payload)
        try await expectTokenTypeRefreshFailure(payload)
    }
}

@Test
func issuedCredentialAcceptsCaseInsensitiveBearerTokenType() async throws {
    let polled = try await pollTokenTypeCredential(
        #"{"access_token":"ghu_poll","token_type":"Bearer"}"#
    )
    #expect(polled.accessToken == "ghu_poll")

    let refreshed = try await refreshTokenTypeCredential(
        #"{"access_token":"ghu_refresh","token_type":"BEARER"}"#
    )
    #expect(refreshed.accessToken == "ghu_refresh")
}

private func expectTokenTypePollFailure(
    _ payload: String
) async throws {
    let transport = TokenTypeTransport([payload])
    let client = tokenTypeClient(transport: transport)
    let connection = try tokenTypeConnection()
    let session = try tokenTypeSession()

    await #expect(throws: GitHubDeviceFlowError.invalidResponse) {
        try await client.pollOnce(
            connection: connection,
            clientID: "Iv1.client",
            session: session
        )
    }
}

private func expectTokenTypeRefreshFailure(
    _ payload: String
) async throws {
    let transport = TokenTypeTransport([payload])
    let client = tokenTypeClient(transport: transport)
    let connection = try tokenTypeConnection()
    let credential = GitHubCredential(
        accessToken: "ghu_old",
        refreshToken: "ghr_old"
    )

    await #expect(throws: GitHubDeviceFlowError.invalidResponse) {
        try await client.refresh(
            connection: connection,
            clientID: "Iv1.client",
            credential: credential
        )
    }
}

private func pollTokenTypeCredential(
    _ payload: String
) async throws -> GitHubCredential {
    let transport = TokenTypeTransport([payload])
    let client = tokenTypeClient(transport: transport)
    let connection = try tokenTypeConnection()
    let session = try tokenTypeSession()
    let result = try await client.pollOnce(
        connection: connection,
        clientID: "Iv1.client",
        session: session
    )

    guard case let .authorized(credential) = result else {
        Issue.record("Expected authorized credential")
        throw GitHubDeviceFlowError.invalidResponse
    }
    return credential
}

private func refreshTokenTypeCredential(
    _ payload: String
) async throws -> GitHubCredential {
    let transport = TokenTypeTransport([payload])
    let client = tokenTypeClient(transport: transport)
    let connection = try tokenTypeConnection()
    let credential = GitHubCredential(
        accessToken: "ghu_old",
        refreshToken: "ghr_old"
    )
    return try await client.refresh(
        connection: connection,
        clientID: "Iv1.client",
        credential: credential
    )
}

private func tokenTypeClient(
    transport: TokenTypeTransport
) -> GitHubDeviceFlowClient {
    GitHubDeviceFlowClient(
        transport: transport,
        now: { tokenTypeNow }
    )
}

private func tokenTypeSession() throws -> GitHubDeviceAuthorizationSession {
    let verificationURI = try #require(
        URL(string: "https://github.com/login/device")
    )
    return GitHubDeviceAuthorizationSession(
        deviceCode: "device",
        userCode: "ABCD-EFGH",
        verificationURI: verificationURI,
        expiresAt: tokenTypeNow.addingTimeInterval(900),
        pollInterval: 5
    )
}

private func tokenTypeConnection() throws -> GitHubConnection {
    let webBaseURL = try #require(URL(string: "https://github.com"))
    return GitHubConnection(
        displayName: "GitHub.com",
        deploymentKind: .githubDotCom,
        webBaseURL: webBaseURL
    )
}

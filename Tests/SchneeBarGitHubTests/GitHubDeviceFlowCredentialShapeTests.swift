import Foundation
import SchneeBarGitHub
import Testing

private actor CredentialShapeTransport: GitHubHTTPTransport {
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

private let credentialShapeNow = Date(timeIntervalSince1970: 1_000)

@Test
func pollRejectsMixedCredentialAndErrorEvidence() async throws {
    try await expectShapePollFailure(
        #"{"access_token":"ghu_new","error":"authorization_pending","token_type":"bearer"}"#
    )
}

@Test
func refreshRejectsMixedCredentialAndErrorEvidence() async throws {
    try await expectShapeRefreshFailure(
        #"{"access_token":"ghu_new","error":"bad_refresh_token","token_type":"bearer"}"#
    )
}

@Test
func pollRejectsIncompleteExpiringCredentialShape() async throws {
    let payloads: [String] = [
        #"{"access_token":"ghu_new","expires_in":28800,"token_type":"bearer"}"#,
        #"{"access_token":"ghu_new","expires_in":28800,"refresh_token":"ghr_new","token_type":"bearer"}"#,
        #"{"access_token":"ghu_new","refresh_token":"ghr_new","refresh_token_expires_in":15897600,"token_type":"bearer"}"#,
    ]

    for payload in payloads {
        try await expectShapePollFailure(payload)
    }
}

@Test
func refreshRejectsIncompleteOrNonPositiveRotationMetadata() async throws {
    let payloads: [String] = [
        #"{"access_token":"ghu_new","expires_in":28800,"token_type":"bearer"}"#,
        #"{"access_token":"ghu_new","expires_in":28800,"refresh_token":"ghr_new","token_type":"bearer"}"#,
        #"{"access_token":"ghu_new","refresh_token":"ghr_new","refresh_token_expires_in":15897600,"token_type":"bearer"}"#,
        #"{"access_token":"ghu_new","expires_in":0,"refresh_token":"ghr_new","refresh_token_expires_in":15897600,"token_type":"bearer"}"#,
        #"{"access_token":"ghu_new","expires_in":28800,"refresh_token":"ghr_new","refresh_token_expires_in":0,"token_type":"bearer"}"#,
    ]

    for payload in payloads {
        try await expectShapeRefreshFailure(payload)
    }
}

@Test
func refreshAcceptsCompleteRotatedCredentialShape() async throws {
    let transport = CredentialShapeTransport([
        #"{"access_token":"ghu_rotated","expires_in":28800,"refresh_token":"ghr_rotated","refresh_token_expires_in":15897600,"token_type":"bearer"}"#,
    ])
    let client = credentialShapeClient(transport: transport)

    let credential = try await client.refresh(
        connection: try credentialShapeConnection(),
        clientID: "Iv1.client",
        credential: GitHubCredential(
            accessToken: "ghu_old",
            refreshToken: "ghr_old"
        )
    )

    #expect(credential.accessToken == "ghu_rotated")
    #expect(credential.refreshToken == "ghr_rotated")
    #expect(
        credential.accessTokenExpiresAt
            == credentialShapeNow.addingTimeInterval(28_800)
    )
    #expect(
        credential.refreshTokenExpiresAt
            == credentialShapeNow.addingTimeInterval(15_897_600)
    )
}

@Test
func refreshAcceptsDocumentedNonExpiringCredentialShape() async throws {
    let transport = CredentialShapeTransport([
        #"{"access_token":"ghu_nonexpiring","token_type":"bearer"}"#,
    ])
    let client = credentialShapeClient(transport: transport)

    let credential = try await client.refresh(
        connection: try credentialShapeConnection(),
        clientID: "Iv1.client",
        credential: GitHubCredential(
            accessToken: "ghu_old",
            refreshToken: "ghr_old"
        )
    )

    #expect(credential.accessToken == "ghu_nonexpiring")
    #expect(credential.refreshToken == nil)
    #expect(credential.accessTokenExpiresAt == nil)
    #expect(credential.refreshTokenExpiresAt == nil)
}

private func expectShapePollFailure(
    _ payload: String
) async throws {
    let transport = CredentialShapeTransport([payload])
    let client = credentialShapeClient(transport: transport)

    await #expect(throws: GitHubDeviceFlowError.invalidResponse) {
        try await client.pollOnce(
            connection: try credentialShapeConnection(),
            clientID: "Iv1.client",
            session: try credentialShapeSession()
        )
    }
}

private func expectShapeRefreshFailure(
    _ payload: String
) async throws {
    let transport = CredentialShapeTransport([payload])
    let client = credentialShapeClient(transport: transport)

    await #expect(throws: GitHubDeviceFlowError.invalidResponse) {
        try await client.refresh(
            connection: try credentialShapeConnection(),
            clientID: "Iv1.client",
            credential: GitHubCredential(
                accessToken: "ghu_old",
                refreshToken: "ghr_old"
            )
        )
    }
}

private func credentialShapeClient(
    transport: CredentialShapeTransport
) -> GitHubDeviceFlowClient {
    GitHubDeviceFlowClient(
        transport: transport,
        now: { credentialShapeNow }
    )
}

private func credentialShapeSession() throws -> GitHubDeviceAuthorizationSession {
    GitHubDeviceAuthorizationSession(
        deviceCode: "device",
        userCode: "ABCD-EFGH",
        verificationURI: try #require(
            URL(string: "https://github.com/login/device")
        ),
        expiresAt: credentialShapeNow.addingTimeInterval(900),
        pollInterval: 5
    )
}

private func credentialShapeConnection() throws -> GitHubConnection {
    GitHubConnection(
        displayName: "GitHub.com",
        deploymentKind: .githubDotCom,
        webBaseURL: try #require(URL(string: "https://github.com"))
    )
}

import Foundation
import SchneeBarGitHub
import Testing

private actor CredentialLifetimeTransport: GitHubHTTPTransport {
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

private let credentialLifetimeNow = Date(timeIntervalSince1970: 1_000)

@Test
func pollRejectsOversizedCredentialLifetimes() async throws {
    let payloads: [String] = [
        #"{"access_token":"ghu_new","expires_in":604801,"refresh_token":"ghr_new","refresh_token_expires_in":15897600,"token_type":"bearer"}"#,
        #"{"access_token":"ghu_new","expires_in":28800,"refresh_token":"ghr_new","refresh_token_expires_in":63072001,"token_type":"bearer"}"#,
    ]

    for payload in payloads {
        let transport = CredentialLifetimeTransport([payload])
        let client = credentialLifetimeClient(transport: transport)

        await #expect(throws: GitHubDeviceFlowError.invalidResponse) {
            try await client.pollOnce(
                connection: try credentialLifetimeConnection(),
                clientID: "Iv1.client",
                session: try credentialLifetimeSession()
            )
        }
    }
}

@Test
func refreshRejectsOversizedCredentialLifetimes() async throws {
    let payloads: [String] = [
        #"{"access_token":"ghu_new","expires_in":604801,"refresh_token":"ghr_new","refresh_token_expires_in":15897600,"token_type":"bearer"}"#,
        #"{"access_token":"ghu_new","expires_in":28800,"refresh_token":"ghr_new","refresh_token_expires_in":63072001,"token_type":"bearer"}"#,
    ]

    for payload in payloads {
        let transport = CredentialLifetimeTransport([payload])
        let client = credentialLifetimeClient(transport: transport)

        await #expect(throws: GitHubDeviceFlowError.invalidResponse) {
            try await client.refresh(
                connection: try credentialLifetimeConnection(),
                clientID: "Iv1.client",
                credential: GitHubCredential(
                    accessToken: "ghu_old",
                    refreshToken: "ghr_old"
                )
            )
        }
    }
}

private func credentialLifetimeClient(
    transport: CredentialLifetimeTransport
) -> GitHubDeviceFlowClient {
    GitHubDeviceFlowClient(
        transport: transport,
        now: { credentialLifetimeNow }
    )
}

private func credentialLifetimeSession() throws -> GitHubDeviceAuthorizationSession {
    GitHubDeviceAuthorizationSession(
        deviceCode: "device",
        userCode: "ABCD-EFGH",
        verificationURI: try #require(
            URL(string: "https://github.com/login/device")
        ),
        expiresAt: credentialLifetimeNow.addingTimeInterval(900),
        pollInterval: 5
    )
}

private func credentialLifetimeConnection() throws -> GitHubConnection {
    GitHubConnection(
        displayName: "GitHub.com",
        deploymentKind: .githubDotCom,
        webBaseURL: try #require(URL(string: "https://github.com"))
    )
}

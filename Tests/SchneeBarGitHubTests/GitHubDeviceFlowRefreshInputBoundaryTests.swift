import Foundation
import SchneeBarGitHub
import Testing

private actor RefreshInputBoundaryTransport: GitHubHTTPTransport {
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
func refreshRejectsOversizedStoredRefreshTokenBeforeNetwork() async throws {
    let transport = RefreshInputBoundaryTransport()
    let client = GitHubDeviceFlowClient(transport: transport)
    let oversizedRefreshToken = String(
        repeating: "r",
        count: GitHubDeviceFlowResponsePolicy.maximumOpaqueTokenCharacters + 1
    )

    await #expect(throws: GitHubDeviceFlowError.invalidResponse) {
        try await client.refresh(
            connection: try refreshInputBoundaryConnection(),
            clientID: "Iv1.client",
            credential: GitHubCredential(
                accessToken: "ghu_old",
                refreshToken: oversizedRefreshToken
            )
        )
    }

    #expect(await transport.requestCount() == 0)
}

private func refreshInputBoundaryConnection() throws -> GitHubConnection {
    GitHubConnection(
        displayName: "GitHub.com",
        deploymentKind: .githubDotCom,
        webBaseURL: try #require(URL(string: "https://github.com"))
    )
}

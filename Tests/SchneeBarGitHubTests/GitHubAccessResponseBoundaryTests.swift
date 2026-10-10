import Foundation
import SchneeBarGitHub
import Testing

private actor AccessResponseBoundaryTransport: GitHubHTTPTransport {
    private let data: Data
    private var requests: [URLRequest] = []

    init(data: Data) {
        self.data = data
    }

    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        requests.append(request)
        let response = try #require(
            HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: "HTTP/1.1",
                headerFields: nil
            )
        )
        return (data, response)
    }

    func recordedRequests() -> [URLRequest] {
        requests
    }
}

@Test
func oversizedAuthenticatedAccountResponseFailsBeforeDecode() async throws {
    let padding = String(repeating: "x", count: 8 * 1024 * 1024)
    let json = #"{"id":42,"login":"octocat","name":null,"avatar_url":null,"padding":"\#(padding)"}"#
    let transport = AccessResponseBoundaryTransport(data: Data(json.utf8))
    let client = GitHubAccessClient(transport: transport)

    await #expect(throws: GitHubAccessClientError.invalidResponse) {
        _ = try await client.authenticatedAccount(
            connection: try accessResponseBoundaryConnection(),
            credential: GitHubCredential(accessToken: "ghu_access")
        )
    }

    #expect(await transport.recordedRequests().count == 1)
}

private func accessResponseBoundaryConnection() throws -> GitHubConnection {
    GitHubConnection(
        displayName: "GitHub.com",
        deploymentKind: .githubDotCom,
        webBaseURL: try #require(URL(string: "https://github.com"))
    )
}

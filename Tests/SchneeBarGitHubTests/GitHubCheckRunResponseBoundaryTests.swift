import Foundation
import SchneeBarGitHub
import Testing

private actor CheckRunBoundaryTransport: GitHubHTTPTransport {
    private let data: Data
    private var requests: [URLRequest] = []

    init(data: Data) {
        self.data = data
    }

    func data(
        for request: URLRequest
    ) async throws -> (Data, HTTPURLResponse) {
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
func oversizedCheckRunsResponseFailsBeforeDecode() async throws {
    let padding = String(repeating: "x", count: 8 * 1024 * 1024)
    let json = #"{\"total_count\":0,\"check_runs\":[],\"padding\":\"\#(padding)\"}"#
    let transport = CheckRunBoundaryTransport(data: Data(json.utf8))
    let client = GitHubCheckRunClient(transport: transport)

    await #expect(throws: GitHubCheckRunClientError.invalidResponse) {
        _ = try await client.checkRuns(
            repository: try checkRunBoundaryRepository(),
            headSHA: String(repeating: "a", count: 40),
            connection: try checkRunBoundaryConnection(),
            credential: GitHubCredential(accessToken: "ghu_checks")
        )
    }

    #expect(await transport.recordedRequests().count == 1)
}

private func checkRunBoundaryConnection() throws -> GitHubConnection {
    GitHubConnection(
        displayName: "GitHub.com",
        deploymentKind: .githubDotCom,
        webBaseURL: try #require(URL(string: "https://github.com"))
    )
}

private func checkRunBoundaryRepository() throws -> GitHubRepositoryAccess {
    GitHubRepositoryAccess(
        id: 42,
        name: "project",
        fullName: "octocat/project",
        isPrivate: false,
        webURL: try #require(
            URL(string: "https://github.com/octocat/project")
        ),
        ownerLogin: "octocat",
        permissions: GitHubRepositoryPermissions(pull: true)
    )
}

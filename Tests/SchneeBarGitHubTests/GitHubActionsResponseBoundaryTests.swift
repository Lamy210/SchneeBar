import Foundation
import SchneeBarGitHub
import Testing

private struct ActionsBoundaryResponse: Sendable {
    let data: Data
    let statusCode: Int

    init(data: Data, statusCode: Int = 200) {
        self.data = data
        self.statusCode = statusCode
    }
}

private actor ActionsBoundaryTransport: GitHubHTTPTransport {
    private var responses: [ActionsBoundaryResponse]
    private var requests: [URLRequest] = []

    init(_ responses: [ActionsBoundaryResponse]) {
        self.responses = responses
    }

    func data(
        for request: URLRequest
    ) async throws -> (Data, HTTPURLResponse) {
        requests.append(request)
        let response = responses.isEmpty
            ? ActionsBoundaryResponse(
                data: Data(#"{"message":"Unexpected request"}"#.utf8),
                statusCode: 500
            )
            : responses.removeFirst()
        let httpResponse = try #require(
            HTTPURLResponse(
                url: request.url!,
                statusCode: response.statusCode,
                httpVersion: "HTTP/1.1",
                headerFields: nil
            )
        )
        return (response.data, httpResponse)
    }

    func recordedRequests() -> [URLRequest] {
        requests
    }
}

@Test
func oversizedWorkflowRunsResponseFailsBeforeDecode() async throws {
    let padding = String(repeating: "x", count: 8 * 1024 * 1024)
    let json = #"{"total_count":0,"workflow_runs":[],"padding":"\#(padding)"}"#
    let transport = ActionsBoundaryTransport([
        ActionsBoundaryResponse(data: Data(json.utf8))
    ])
    let client = GitHubActionsClient(transport: transport)

    await #expect(throws: GitHubActionsClientError.invalidResponse) {
        _ = try await client.workflowRuns(
            repository: try actionsBoundaryRepository(),
            connection: try actionsBoundaryConnection(),
            credential: GitHubCredential(accessToken: "ghu_actions")
        )
    }

    #expect(await transport.recordedRequests().count == 1)
}

private func actionsBoundaryConnection() throws -> GitHubConnection {
    GitHubConnection(
        displayName: "GitHub.com",
        deploymentKind: .githubDotCom,
        webBaseURL: try #require(URL(string: "https://github.com"))
    )
}

private func actionsBoundaryRepository() throws -> GitHubRepositoryAccess {
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

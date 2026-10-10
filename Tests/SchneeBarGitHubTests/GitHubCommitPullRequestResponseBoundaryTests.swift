import Foundation
import SchneeBarGitHub
import Testing

private actor CommitPullRequestResponseBoundaryTransport: GitHubHTTPTransport {
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
func oversizedCommitPullRequestResponseFailsBeforeDecode() async throws {
    let padding = String(repeating: "x", count: 8 * 1024 * 1024)
    let json = #"[{"number":25,"padding":"\#(padding)"}]"#
    let transport = CommitPullRequestResponseBoundaryTransport(data: Data(json.utf8))
    let client = GitHubCommitPullRequestClient(transport: transport)

    await #expect(throws: GitHubCommitPullRequestClientError.invalidResponse) {
        _ = try await client.firstPagePullRequestNumbers(
            for: "landed-sha",
            repository: try commitPullRequestResponseBoundaryRepository(),
            connection: try commitPullRequestResponseBoundaryConnection(),
            credential: GitHubCredential(accessToken: "ghu_commit")
        )
    }

    #expect(await transport.recordedRequests().count == 1)
}

private func commitPullRequestResponseBoundaryConnection() throws -> GitHubConnection {
    GitHubConnection(
        displayName: "GitHub.com",
        deploymentKind: .githubDotCom,
        webBaseURL: try #require(URL(string: "https://github.com"))
    )
}

private func commitPullRequestResponseBoundaryRepository() throws -> GitHubRepositoryAccess {
    GitHubRepositoryAccess(
        id: 42,
        name: "project",
        fullName: "octocat/project",
        isPrivate: false,
        webURL: try #require(URL(string: "https://github.com/octocat/project")),
        ownerLogin: "octocat",
        permissions: GitHubRepositoryPermissions(pull: true)
    )
}

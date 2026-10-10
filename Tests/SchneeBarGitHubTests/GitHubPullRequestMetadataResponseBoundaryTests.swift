import Foundation
import SchneeBarGitHub
import Testing

private actor PullRequestMetadataResponseBoundaryTransport: GitHubHTTPTransport {
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
func oversizedPullRequestMetadataResponseFailsBeforeDecode() async throws {
    let padding = String(repeating: "x", count: 8 * 1024 * 1024)
    let json = #"{"number":25,"state":"open","draft":false,"merged":false,"merge_commit_sha":null,"head":{"ref":"feature","sha":"head-sha"},"base":{"ref":"main","sha":"base-sha"},"updated_at":"2026-09-18T00:01:00Z","merged_at":null,"padding":"\#(padding)"}"#
    let transport = PullRequestMetadataResponseBoundaryTransport(data: Data(json.utf8))
    let client = GitHubPullRequestMetadataClient(transport: transport)

    await #expect(throws: GitHubPullRequestMetadataClientError.invalidResponse) {
        _ = try await client.pullRequest(
            number: 25,
            repository: try pullRequestMetadataResponseBoundaryRepository(),
            connection: try pullRequestMetadataResponseBoundaryConnection(),
            credential: GitHubCredential(accessToken: "ghu_metadata")
        )
    }

    #expect(await transport.recordedRequests().count == 1)
}

private func pullRequestMetadataResponseBoundaryConnection() throws -> GitHubConnection {
    GitHubConnection(
        displayName: "GitHub.com",
        deploymentKind: .githubDotCom,
        webBaseURL: try #require(URL(string: "https://github.com"))
    )
}

private func pullRequestMetadataResponseBoundaryRepository() throws -> GitHubRepositoryAccess {
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

import Foundation
import SchneeBarGitHub
import Testing

private actor EnvironmentResponseBoundaryTransport: GitHubHTTPTransport {
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
func oversizedEnvironmentResponseFailsBeforeDecode() async throws {
    let padding = String(repeating: "x", count: 8 * 1024 * 1024)
    let json = #"{"total_count":1,"environments":[{"id":901,"name":"production","protection_rules":[],"deployment_branch_policy":null,"created_at":null,"updated_at":null}],"padding":"\#(padding)"}"#
    let transport = EnvironmentResponseBoundaryTransport(data: Data(json.utf8))
    let client = GitHubEnvironmentClient(transport: transport)

    await #expect(throws: GitHubEnvironmentClientError.invalidResponse) {
        _ = try await client.environments(
            repository: try environmentResponseBoundaryRepository(),
            connection: try environmentResponseBoundaryConnection(),
            credential: GitHubCredential(accessToken: "ghu_environment")
        )
    }

    #expect(await transport.recordedRequests().count == 1)
}

private func environmentResponseBoundaryConnection() throws -> GitHubConnection {
    GitHubConnection(
        displayName: "GitHub.com",
        deploymentKind: .githubDotCom,
        webBaseURL: try #require(URL(string: "https://github.com"))
    )
}

private func environmentResponseBoundaryRepository() throws -> GitHubRepositoryAccess {
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

import Foundation
import SchneeBarGitHub
import Testing

private actor DeploymentResponseBoundaryTransport: GitHubHTTPTransport {
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
func oversizedDeploymentResponseFailsBeforeDecode() async throws {
    let padding = String(repeating: "x", count: 8 * 1024 * 1024)
    let json = #"[{"id":901,"sha":"landed-sha","environment":"production","production_environment":true,"transient_environment":false,"created_at":"2026-09-18T00:00:00Z","updated_at":"2026-09-18T00:01:00Z","padding":"\#(padding)"}]"#
    let transport = DeploymentResponseBoundaryTransport(data: Data(json.utf8))
    let client = GitHubDeploymentClient(transport: transport)

    await #expect(throws: GitHubDeploymentClientError.invalidResponse) {
        _ = try await client.deployments(
            sha: "landed-sha",
            repository: try deploymentResponseBoundaryRepository(),
            connection: try deploymentResponseBoundaryConnection(),
            credential: GitHubCredential(accessToken: "ghu_deploy")
        )
    }

    #expect(await transport.recordedRequests().count == 1)
}

private func deploymentResponseBoundaryConnection() throws -> GitHubConnection {
    GitHubConnection(
        displayName: "GitHub.com",
        deploymentKind: .githubDotCom,
        webBaseURL: try #require(URL(string: "https://github.com"))
    )
}

private func deploymentResponseBoundaryRepository() throws -> GitHubRepositoryAccess {
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

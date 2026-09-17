import Foundation
import SchneeBarGitHub
import Testing

private actor ExactRunTransport: GitHubHTTPTransport {
    private let json: String
    private let statusCode: Int
    private var requests: [URLRequest] = []

    init(json: String, statusCode: Int = 200) {
        self.json = json
        self.statusCode = statusCode
    }

    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        requests.append(request)
        let response = try #require(
            HTTPURLResponse(
                url: request.url!,
                statusCode: statusCode,
                httpVersion: "HTTP/1.1",
                headerFields: nil
            )
        )
        return (Data(json.utf8), response)
    }

    func recordedRequests() -> [URLRequest] {
        requests
    }
}

@Test
func loadsExactHostedWorkflowRunWithTrustedDestination() async throws {
    let transport = ExactRunTransport(
        json: #"{"id":501,"workflow_id":88,"name":"CI","display_title":"Fix widget refresh","event":"pull_request","status":"in_progress","conclusion":null,"run_number":42,"head_branch":"feature/widgets","head_sha":"abc123","pull_requests":[{"number":27}],"created_at":"2026-09-12T12:00:00Z","updated_at":"2026-09-12T12:01:00Z","html_url":"https://evil.example/run"}"#
    )
    let client = GitHubActionsClient(transport: transport)

    let run = try await client.workflowRun(
        id: 501,
        repository: try exactRunRepository(),
        connection: try exactRunGitHubDotComConnection(),
        credential: GitHubCredential(accessToken: "ghu_actions")
    )

    #expect(run.id == 501)
    #expect(run.workflowID == 88)
    #expect(run.status == .inProgress)
    #expect(run.pullRequestNumbers == [27])
    #expect(run.webURL.absoluteString == "https://github.com/octocat/project/actions/runs/501")

    let request = try #require(await transport.recordedRequests().first)
    #expect(request.httpMethod == "GET")
    #expect(request.url?.path == "/repos/octocat/project/actions/runs/501")
    #expect(request.url?.query == nil)
    #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer ghu_actions")
    #expect(request.value(forHTTPHeaderField: "X-GitHub-Api-Version") == "2026-03-10")
}

@Test
func exactWorkflowRunRejectsNonPositiveIDBeforeNetwork() async throws {
    let transport = ExactRunTransport(json: #"{}"#)
    let client = GitHubActionsClient(transport: transport)

    await #expect(throws: GitHubActionsClientError.invalidRunID) {
        try await client.workflowRun(
            id: 0,
            repository: exactRunRepository(),
            connection: exactRunGitHubDotComConnection(),
            credential: GitHubCredential(accessToken: "ghu_actions")
        )
    }

    #expect(await transport.recordedRequests().isEmpty)
}

@Test
func loadsExactWorkflowRunFromCustomPortGHES() async throws {
    let transport = ExactRunTransport(
        json: #"{"id":901,"workflow_id":77,"name":"Release","display_title":"Release","event":"push","status":"completed","conclusion":"success","run_number":3,"head_branch":"main","head_sha":"def456","pull_requests":[],"created_at":"2026-09-12T10:00:00Z","updated_at":"2026-09-12T10:02:00Z"}"#
    )
    let client = GitHubActionsClient(transport: transport)
    var connection = GitHubConnection(
        displayName: "Internal GitHub",
        deploymentKind: .enterpriseServer,
        webBaseURL: try #require(URL(string: "https://github.internal.example:8443"))
    )
    connection.apiVersion = "2022-11-28"

    let run = try await client.workflowRun(
        id: 901,
        repository: try exactRunRepository(
            owner: "acme",
            name: "service-api",
            webBaseURL: "https://github.internal.example:8443"
        ),
        connection: connection,
        credential: GitHubCredential(accessToken: "ghu_enterprise")
    )

    #expect(run.conclusion == .success)
    #expect(run.webURL.absoluteString == "https://github.internal.example:8443/acme/service-api/actions/runs/901")

    let request = try #require(await transport.recordedRequests().first)
    #expect(request.url?.host == "github.internal.example")
    #expect(request.url?.port == 8443)
    #expect(request.url?.path == "/api/v3/repos/acme/service-api/actions/runs/901")
    #expect(request.value(forHTTPHeaderField: "X-GitHub-Api-Version") == "2022-11-28")
}

private func exactRunGitHubDotComConnection() throws -> GitHubConnection {
    GitHubConnection(
        displayName: "GitHub.com",
        deploymentKind: .githubDotCom,
        webBaseURL: try #require(URL(string: "https://github.com"))
    )
}

private func exactRunRepository(
    owner: String = "octocat",
    name: String = "project",
    webBaseURL: String = "https://github.com"
) throws -> GitHubRepositoryAccess {
    GitHubRepositoryAccess(
        id: 42,
        name: name,
        fullName: "\(owner)/\(name)",
        isPrivate: false,
        webURL: try #require(URL(string: "\(webBaseURL)/\(owner)/\(name)")),
        ownerLogin: owner,
        permissions: GitHubRepositoryPermissions(pull: true)
    )
}

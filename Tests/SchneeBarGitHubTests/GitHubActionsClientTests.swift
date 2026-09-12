import Foundation
import SchneeBarGitHub
import Testing

private struct ActionsStubResponse: Sendable {
    let json: String
    let statusCode: Int

    init(_ json: String, statusCode: Int = 200) {
        self.json = json
        self.statusCode = statusCode
    }
}

private actor ActionsQueueTransport: GitHubHTTPTransport {
    private var responses: [ActionsStubResponse]
    private var requests: [URLRequest] = []

    init(_ responses: [ActionsStubResponse]) {
        self.responses = responses
    }

    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        requests.append(request)
        let response = responses.isEmpty
            ? ActionsStubResponse(#"{"message":"Unexpected request"}"#, statusCode: 500)
            : responses.removeFirst()
        let httpResponse = try #require(
            HTTPURLResponse(
                url: request.url!,
                statusCode: response.statusCode,
                httpVersion: "HTTP/1.1",
                headerFields: nil
            )
        )
        return (Data(response.json.utf8), httpResponse)
    }

    func recordedRequests() -> [URLRequest] {
        requests
    }
}

@Test
func loadsHostedWorkflowRunsWithFiltersAndTrustedWebURL() async throws {
    let transport = ActionsQueueTransport([
        ActionsStubResponse(
            #"{"total_count":1,"workflow_runs":[{"id":501,"workflow_id":88,"name":"CI","display_title":"Fix widget refresh","event":"pull_request","status":"in_progress","conclusion":null,"run_number":42,"head_branch":"feature/widgets","head_sha":"abc123","pull_requests":[{"number":27}],"created_at":"2026-09-12T12:00:00Z","updated_at":"2026-09-12T12:01:00Z","html_url":"https://evil.example/run"}]}"#
        )
    ])
    let client = GitHubActionsClient(transport: transport)

    let runs = try await client.workflowRuns(
        repository: try actionsRepository(),
        connection: try actionsGitHubDotComConnection(),
        credential: GitHubCredential(accessToken: "ghu_actions"),
        query: GitHubWorkflowRunQuery(
            branch: "feature/widgets",
            event: "pull_request",
            status: .inProgress,
            limit: 25
        )
    )

    let run = try #require(runs.first)
    #expect(run.id == 501)
    #expect(run.workflowID == 88)
    #expect(run.name == "CI")
    #expect(run.displayTitle == "Fix widget refresh")
    #expect(run.status == .inProgress)
    #expect(run.conclusion == nil)
    #expect(run.pullRequestNumbers == [27])
    #expect(run.webURL.absoluteString == "https://github.com/octocat/project/actions/runs/501")

    let request = try #require(await transport.recordedRequests().first)
    #expect(request.url?.path == "/repos/octocat/project/actions/runs")
    #expect(queryValue("branch", in: request) == "feature/widgets")
    #expect(queryValue("event", in: request) == "pull_request")
    #expect(queryValue("status", in: request) == "in_progress")
    #expect(queryValue("per_page", in: request) == "25")
    #expect(queryValue("page", in: request) == "1")
    #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer ghu_actions")
    #expect(request.value(forHTTPHeaderField: "X-GitHub-Api-Version") == "2026-03-10")
}

@Test
func loadsWorkflowRunsFromCustomPortGHESWithNegotiatedVersion() async throws {
    let transport = ActionsQueueTransport([
        ActionsStubResponse(
            #"{"total_count":1,"workflow_runs":[{"id":901,"workflow_id":77,"name":"Release","display_title":"Release","event":"push","status":"completed","conclusion":"success","run_number":3,"head_branch":"main","head_sha":"def456","pull_requests":[],"created_at":"2026-09-12T10:00:00Z","updated_at":"2026-09-12T10:02:00Z"}]}"#
        )
    ])
    let client = GitHubActionsClient(transport: transport)
    var connection = GitHubConnection(
        displayName: "Internal GitHub",
        deploymentKind: .enterpriseServer,
        webBaseURL: try #require(URL(string: "https://github.internal.example:8443"))
    )
    connection.apiVersion = "2022-11-28"

    let runs = try await client.workflowRuns(
        repository: try actionsRepository(
            owner: "acme",
            name: "service-api",
            webBaseURL: "https://github.internal.example:8443"
        ),
        connection: connection,
        credential: GitHubCredential(accessToken: "ghu_enterprise")
    )

    let run = try #require(runs.first)
    #expect(run.status == .completed)
    #expect(run.conclusion == .success)
    #expect(run.webURL.absoluteString == "https://github.internal.example:8443/acme/service-api/actions/runs/901")

    let request = try #require(await transport.recordedRequests().first)
    #expect(request.url?.host == "github.internal.example")
    #expect(request.url?.port == 8443)
    #expect(request.url?.path == "/api/v3/repos/acme/service-api/actions/runs")
    #expect(request.value(forHTTPHeaderField: "X-GitHub-Api-Version") == "2022-11-28")
}

@Test
func paginatesWorkflowRunsUpToRequestedLimit() async throws {
    let first = #"{"total_count":2,"workflow_runs":[{"id":1,"workflow_id":10,"name":"CI","display_title":"One","event":"push","status":"completed","conclusion":"success","run_number":1,"head_branch":"main","head_sha":"sha1","pull_requests":[],"created_at":"2026-09-12T10:00:00Z","updated_at":"2026-09-12T10:01:00Z"}]}"#
    let second = #"{"total_count":2,"workflow_runs":[{"id":2,"workflow_id":10,"name":"CI","display_title":"Two","event":"push","status":"completed","conclusion":"failure","run_number":2,"head_branch":"main","head_sha":"sha2","pull_requests":[],"created_at":"2026-09-12T11:00:00Z","updated_at":"2026-09-12T11:01:00Z"}]}"#
    let transport = ActionsQueueTransport([
        ActionsStubResponse(first),
        ActionsStubResponse(second),
    ])
    let client = GitHubActionsClient(transport: transport)

    let runs = try await client.workflowRuns(
        repository: try actionsRepository(),
        connection: try actionsGitHubDotComConnection(),
        credential: GitHubCredential(accessToken: "ghu_actions"),
        query: GitHubWorkflowRunQuery(limit: 2)
    )

    #expect(runs.map(\.id) == [1, 2])
    let requests = await transport.recordedRequests()
    #expect(requests.count == 2)
    #expect(queryValue("per_page", in: requests[0]) == "2")
    #expect(queryValue("per_page", in: requests[1]) == "1")
    #expect(queryValue("page", in: requests[1]) == "2")
}

@Test
func preservesUnknownWorkflowStateWithoutFailingWholePayload() async throws {
    let transport = ActionsQueueTransport([
        ActionsStubResponse(
            #"{"total_count":1,"workflow_runs":[{"id":7,"workflow_id":9,"name":null,"display_title":null,"event":"future_event","status":"future_status","conclusion":"future_conclusion","run_number":1,"head_branch":null,"head_sha":"future-sha","pull_requests":[],"created_at":"2026-09-12T10:00:00.123Z","updated_at":"2026-09-12T10:00:01.456Z"}]}"#
        )
    ])
    let client = GitHubActionsClient(transport: transport)

    let run = try #require(
        try await client.workflowRuns(
            repository: actionsRepository(),
            connection: actionsGitHubDotComConnection(),
            credential: GitHubCredential(accessToken: "ghu_actions")
        ).first
    )

    #expect(run.name == "Workflow #9")
    #expect(run.displayTitle == "Workflow #9")
    #expect(run.status == .unknown("future_status"))
    #expect(run.conclusion == .unknown("future_conclusion"))
}

@Test
func emptyWorkflowCredentialStopsBeforeNetworkRequest() async throws {
    let transport = ActionsQueueTransport([])
    let client = GitHubActionsClient(transport: transport)

    await #expect(throws: GitHubActionsClientError.invalidCredential) {
        try await client.workflowRuns(
            repository: actionsRepository(),
            connection: actionsGitHubDotComConnection(),
            credential: GitHubCredential(accessToken: "   ")
        )
    }

    #expect(await transport.recordedRequests().isEmpty)
}

@Test
func mapsWorkflowHTTPFailure() async throws {
    let transport = ActionsQueueTransport([
        ActionsStubResponse(#"{"message":"Forbidden"}"#, statusCode: 403)
    ])
    let client = GitHubActionsClient(transport: transport)

    await #expect(throws: GitHubActionsClientError.httpStatus(403)) {
        try await client.workflowRuns(
            repository: actionsRepository(),
            connection: actionsGitHubDotComConnection(),
            credential: GitHubCredential(accessToken: "ghu_actions")
        )
    }
}

private func actionsGitHubDotComConnection() throws -> GitHubConnection {
    GitHubConnection(
        displayName: "GitHub.com",
        deploymentKind: .githubDotCom,
        webBaseURL: try #require(URL(string: "https://github.com"))
    )
}

private func actionsRepository(
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

private func queryValue(_ name: String, in request: URLRequest) -> String? {
    guard let url = request.url,
          let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
    else {
        return nil
    }
    return components.queryItems?.first(where: { $0.name == name })?.value
}

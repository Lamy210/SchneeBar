import Foundation
import SchneeBarGitHub
import Testing

private actor HistoryBudgetCredentialStore: GitHubCredentialStore {
    private var values: [GitHubCredentialKey: GitHubCredential] = [:]

    func load(for key: GitHubCredentialKey) async throws -> GitHubCredential? {
        values[key]
    }

    func save(_ credential: GitHubCredential, for key: GitHubCredentialKey) async throws {
        values[key] = credential
    }

    func delete(for key: GitHubCredentialKey) async throws {
        values.removeValue(forKey: key)
    }
}

private actor HistoryBudgetTransport: GitHubHTTPTransport {
    private var requests: [URLRequest] = []

    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        requests.append(request)
        let url = try #require(request.url)
        let json: String
        let statusCode: Int

        if url.path == "/repos/octocat/project/actions/runs" {
            json = """
            {"total_count":1,"workflow_runs":[{"id":900,"workflow_id":88,"name":"CI","display_title":"CI","event":"push","status":"completed","conclusion":"success","run_number":900,"head_branch":"main","head_sha":"head-sha","pull_requests":[],"created_at":"2026-09-20T00:00:00Z","updated_at":"2026-09-20T00:01:00Z"}]}
            """
            statusCode = 200
        } else {
            json = #"{"message":"Unexpected request"}"#
            statusCode = 500
        }

        let response = try #require(
            HTTPURLResponse(
                url: url,
                statusCode: statusCode,
                httpVersion: "HTTP/1.1",
                headerFields: nil
            )
        )
        return (Data(json.utf8), response)
    }

    func recordedRequests() -> [URLRequest] { requests }
}

@Test
func deliveryHistoryListUsesExactlyOneCompletedRunsRequest() async throws {
    let connection = GitHubConnection(
        id: UUID(uuidString: "77777777-8888-9999-aaaa-bbbbbbbbbbbb")!,
        displayName: "GitHub.com",
        deploymentKind: .githubDotCom,
        webBaseURL: try #require(URL(string: "https://github.com"))
    )
    let identity = GitHubAccountIdentity(id: "100", login: "octocat")
    let repository = GitHubRepositoryAccess(
        id: 42,
        name: "project",
        fullName: "octocat/project",
        isPrivate: false,
        webURL: try #require(URL(string: "https://github.com/octocat/project")),
        ownerLogin: "octocat",
        permissions: GitHubRepositoryPermissions(pull: true),
        defaultBranch: "main"
    )
    let store = HistoryBudgetCredentialStore()
    try await store.save(
        GitHubCredential(accessToken: "ghu_history_budget"),
        for: GitHubCredentialKey(connectionID: connection.id, accountID: identity.id)
    )
    let transport = HistoryBudgetTransport()
    let service = GitHubWorkflowRunService(
        sessionCoordinator: GitHubConnectionSessionCoordinator(credentialStore: store),
        actionsClient: GitHubActionsClient(transport: transport)
    )

    let runs = try await service.workflowRuns(
        connection: connection,
        identity: identity,
        clientID: nil,
        repository: repository,
        query: GitHubWorkflowRunQuery(
            status: .completed,
            limit: 20
        )
    )

    #expect(runs.map(\.id) == [900])

    let requests = await transport.recordedRequests()
    #expect(requests.count == 1)
    let request = try #require(requests.first)
    #expect(request.url?.path == "/repos/octocat/project/actions/runs")
    #expect(queryValue("status", in: request) == "completed")
    #expect(queryValue("per_page", in: request) == "20")
    #expect(queryValue("page", in: request) == "1")
    #expect(queryValue("branch", in: request) == nil)
    #expect(queryValue("event", in: request) == nil)

    let path = request.url?.path ?? ""
    #expect(!path.contains("/pulls/"))
    #expect(!path.contains("/commits/"))
    #expect(!path.contains("/deployments"))
    #expect(!path.contains("/environments"))
    #expect(!path.contains("/jobs"))
}

private func queryValue(
    _ name: String,
    in request: URLRequest
) -> String? {
    guard let url = request.url,
          let components = URLComponents(
              url: url,
              resolvingAgainstBaseURL: false
          )
    else {
        return nil
    }
    return components.queryItems?
        .first(where: { $0.name == name })?
        .value
}

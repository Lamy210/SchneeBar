import Foundation
import SchneeBarGitHub
import Testing

private actor DeliveryBudgetCredentialStore: GitHubCredentialStore {
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

private actor DeliveryBudgetRoutingTransport: GitHubHTTPTransport {
    private var requests: [URLRequest] = []

    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        requests.append(request)
        let url = try #require(request.url)
        let path = url.path

        let json: String
        let statusCode: Int

        switch path {
        case "/repos/octocat/project/actions/runs/700":
            json = deliveryBudgetWorkflowRunJSON(
                id: 700,
                headBranch: "feature/timeline",
                headSHA: "selected-sha",
                pullRequestNumbers: [47],
                updatedAt: "2026-09-18T05:00:00Z"
            )
            statusCode = 200

        case "/repos/octocat/project/pulls/47":
            json = """
            {"number":47,"state":"closed","draft":false,"merged":true,"merge_commit_sha":"merge-sha","head":{"ref":"feature/timeline","sha":"selected-sha"},"base":{"ref":"main","sha":"base-sha"},"updated_at":"2026-09-18T00:31:00Z","merged_at":"2026-09-18T00:30:00Z"}
            """
            statusCode = 200

        case "/repos/octocat/project/actions/runs":
            json = deliveryBudgetWorkflowRunsJSON([
                deliveryBudgetWorkflowRunJSON(id: 801, headSHA: "sha-1", updatedAt: "2026-09-18T04:00:00Z"),
                deliveryBudgetWorkflowRunJSON(id: 802, headSHA: "sha-2", updatedAt: "2026-09-18T03:00:00Z"),
                deliveryBudgetWorkflowRunJSON(id: 803, headSHA: "sha-3", updatedAt: "2026-09-18T02:00:00Z"),
                deliveryBudgetWorkflowRunJSON(id: 804, headSHA: "sha-4", updatedAt: "2026-09-18T01:00:00Z"),
            ])
            statusCode = 200

        case "/repos/octocat/project/commits/sha-1/pulls",
             "/repos/octocat/project/commits/sha-2/pulls",
             "/repos/octocat/project/commits/sha-3/pulls":
            json = "[]"
            statusCode = 200

        case "/repos/octocat/project/commits/sha-4/pulls":
            json = #"[{"number":47}]"#
            statusCode = 200

        case "/repos/octocat/project/deployments":
            json = """
            [
              {"id":901,"sha":"sha-4","environment":"production","production_environment":true,"transient_environment":false,"created_at":"2026-09-18T01:10:00Z","updated_at":"2026-09-18T01:13:00Z"},
              {"id":902,"sha":"sha-4","environment":"staging","production_environment":false,"transient_environment":false,"created_at":"2026-09-18T01:09:00Z","updated_at":"2026-09-18T01:12:00Z"},
              {"id":903,"sha":"sha-4","environment":"preview","production_environment":false,"transient_environment":true,"created_at":"2026-09-18T01:08:00Z","updated_at":"2026-09-18T01:11:00Z"}
            ]
            """
            statusCode = 200

        case "/repos/octocat/project/deployments/901/statuses":
            json = deliveryBudgetStatusJSON(id: 1001, state: "success", environment: "production")
            statusCode = 200

        case "/repos/octocat/project/deployments/902/statuses":
            json = deliveryBudgetStatusJSON(id: 1002, state: "success", environment: "staging")
            statusCode = 200

        case "/repos/octocat/project/deployments/903/statuses":
            json = deliveryBudgetStatusJSON(id: 1003, state: "pending", environment: "preview")
            statusCode = 200

        case "/repos/octocat/project/environments":
            json = """
            {
              "total_count":3,
              "environments":[
                {
                  "id":301,
                  "name":"production",
                  "protection_rules":[
                    {
                      "type":"required_reviewers",
                      "prevent_self_review":true,
                      "reviewers":[{"type":"User","reviewer":{"id":1,"login":"synthetic"}}]
                    },
                    {"type":"wait_timer","wait_timer":30}
                  ],
                  "deployment_branch_policy":{
                    "protected_branches":false,
                    "custom_branch_policies":true
                  },
                  "created_at":"2026-09-18T00:00:00Z",
                  "updated_at":"2026-09-18T00:01:00Z"
                },
                {
                  "id":302,
                  "name":"staging",
                  "protection_rules":[],
                  "deployment_branch_policy":null,
                  "created_at":null,
                  "updated_at":null
                },
                {
                  "id":303,
                  "name":"preview",
                  "protection_rules":[],
                  "created_at":null,
                  "updated_at":null
                }
              ]
            }
            """
            statusCode = 200

        default:
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

    func recordedRequests() -> [URLRequest] {
        requests
    }
}

@Test
func completeDeliveryDeploymentAndEnvironmentEvidencePathUsesTwelveFeatureRequests() async throws {
    let connection = GitHubConnection(
        id: UUID(uuidString: "33333333-4444-5555-6666-777777777777")!,
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
    let store = DeliveryBudgetCredentialStore()
    try await store.save(
        GitHubCredential(accessToken: "ghu_delivery_budget"),
        for: GitHubCredentialKey(connectionID: connection.id, accountID: identity.id)
    )
    let coordinator = GitHubConnectionSessionCoordinator(credentialStore: store)
    let transport = DeliveryBudgetRoutingTransport()

    let deliveryService = GitHubDeliveryTimelineService(
        sessionCoordinator: coordinator,
        actionsClient: GitHubActionsClient(transport: transport),
        pullRequestClient: GitHubPullRequestMetadataClient(transport: transport),
        commitPullRequestClient: GitHubCommitPullRequestClient(transport: transport)
    )
    let deploymentService = GitHubDeploymentTimelineService(
        sessionCoordinator: coordinator,
        deploymentClient: GitHubDeploymentClient(transport: transport)
    )
    let environmentService = GitHubEnvironmentCatalogService(
        sessionCoordinator: coordinator,
        environmentClient: GitHubEnvironmentClient(transport: transport)
    )

    let correlationEvidence = try await deliveryService.timelineEvidence(
        connection: connection,
        identity: identity,
        clientID: nil,
        repository: repository,
        runID: 700
    )

    #expect(correlationEvidence.associatedPullRequestNumbersByRunID[804] == [47])
    #expect(correlationEvidence.repositoryDefaultBranch == "main")

    let beforeDeployment = await transport.recordedRequests()
    #expect(beforeDeployment.count == 7)

    let deploymentEvidence = try await deploymentService.deploymentEvidence(
        connection: connection,
        identity: identity,
        clientID: nil,
        repository: repository,
        exactSHA: "sha-4"
    )

    #expect(deploymentEvidence.deployments.count == 3)

    let environmentCatalog = try await environmentService.environmentCatalog(
        connection: connection,
        identity: identity,
        clientID: nil,
        repository: repository
    )

    #expect(environmentCatalog.environments.count == 3)

    let featureRequests = await transport.recordedRequests()
    #expect(featureRequests.count == 12)
    #expect(
        featureRequests.filter {
            $0.url?.path.contains("/deployments") == true
        }.count == 4
    )
    #expect(
        featureRequests.filter {
            $0.url?.path.contains("/commits/") == true
        }.count == 4
    )

    let environmentRequests = featureRequests.filter {
        $0.url?.path == "/repos/octocat/project/environments"
    }
    #expect(environmentRequests.count == 1)

    let environmentRequest = try #require(environmentRequests.first)
    #expect(queryValue("per_page", in: environmentRequest) == "100")
    #expect(queryValue("page", in: environmentRequest) == "1")
}

private func deliveryBudgetWorkflowRunJSON(
    id: Int64,
    headBranch: String = "main",
    headSHA: String,
    pullRequestNumbers: [Int] = [],
    updatedAt: String
) -> String {
    let pulls = pullRequestNumbers.map { "{\"number\":\($0)}" }.joined(separator: ",")
    return """
    {"id":\(id),"workflow_id":88,"name":"CI","display_title":"CI","event":"push","status":"completed","conclusion":"success","run_number":1,"head_branch":"\(headBranch)","head_sha":"\(headSHA)","pull_requests":[\(pulls)],"created_at":"2026-09-18T00:00:00Z","updated_at":"\(updatedAt)"}
    """
}

private func deliveryBudgetWorkflowRunsJSON(_ runs: [String]) -> String {
    "{\"total_count\":\(runs.count),\"workflow_runs\":[\(runs.joined(separator: ","))]}"
}

private func deliveryBudgetStatusJSON(
    id: Int64,
    state: String,
    environment: String
) -> String {
    """
    [{"id":\(id),"state":"\(state)","environment":"\(environment)","description":null,"environment_url":null,"log_url":null,"created_at":"2026-09-18T01:00:00Z","updated_at":"2026-09-18T01:01:00Z"}]
    """
}


private func queryValue(_ name: String, in request: URLRequest) -> String? {
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

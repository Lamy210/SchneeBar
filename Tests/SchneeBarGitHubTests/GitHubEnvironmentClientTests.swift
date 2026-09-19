import Foundation
import SchneeBarGitHub
import Testing

private struct EnvironmentStubResponse: Sendable {
    let json: String
    let statusCode: Int

    init(_ json: String, statusCode: Int = 200) {
        self.json = json
        self.statusCode = statusCode
    }
}

private actor EnvironmentQueueTransport: GitHubHTTPTransport {
    private var responses: [EnvironmentStubResponse]
    private var requests: [URLRequest] = []

    init(_ responses: [EnvironmentStubResponse]) {
        self.responses = responses
    }

    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        requests.append(request)
        let response = responses.isEmpty
            ? EnvironmentStubResponse(#"{"message":"Unexpected request"}"#, statusCode: 500)
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
func environmentClientLoadsFirstPageAndNormalizesBuiltInProtection() async throws {
    let transport = EnvironmentQueueTransport([
        EnvironmentStubResponse(
            """
            {
              "total_count": 2,
              "environments": [
                {
                  "id": 101,
                  "node_id": "ENV_101",
                  "name": "production",
                  "url": "https://api.github.com/repos/octocat/project/environments/production",
                  "html_url": "https://github.com/octocat/project/deployments/activity_log?environments_filter=production",
                  "created_at": "2026-09-20T00:00:00Z",
                  "updated_at": "2026-09-20T00:01:00Z",
                  "protection_rules": [
                    {
                      "id": 1,
                      "node_id": "RULE_1",
                      "type": "required_reviewers",
                      "prevent_self_review": true,
                      "reviewers": [
                        {"type":"User","reviewer":{"id":55,"login":"private-user"}},
                        {"type":"Team","reviewer":{"id":66,"name":"private-team"}}
                      ]
                    },
                    {
                      "id": 2,
                      "node_id": "RULE_2",
                      "type": "wait_timer",
                      "wait_timer": 30
                    },
                    {
                      "id": 3,
                      "node_id": "RULE_3",
                      "type": "future_rule",
                      "configuration": {"opaque": true}
                    }
                  ],
                  "deployment_branch_policy": {
                    "protected_branches": false,
                    "custom_branch_policies": true
                  }
                },
                {
                  "id": 102,
                  "name": "staging",
                  "created_at": null,
                  "updated_at": null,
                  "protection_rules": [],
                  "deployment_branch_policy": null
                }
              ]
            }
            """
        ),
    ])
    let client = GitHubEnvironmentClient(transport: transport)

    let catalog = try await client.environments(
        repository: environmentRepository(),
        connection: environmentGitHubDotComConnection(),
        credential: GitHubCredential(accessToken: "ghu_environment"),
        limit: 100
    )

    #expect(catalog.totalCount == 2)
    #expect(catalog.environments.count == 2)
    #expect(!catalog.isTruncated)

    let production = try #require(catalog.environments.first)
    #expect(production.id == 101)
    #expect(production.name == "production")
    #expect(production.protection.requiredReviewerCount == 2)
    #expect(production.protection.preventsSelfReview == true)
    #expect(production.protection.waitTimerMinutes == 30)
    #expect(production.protection.branchPolicy == .customBranches)
    #expect(production.createdAt != nil)
    #expect(production.updatedAt != nil)

    let staging = try #require(catalog.environments.last)
    #expect(staging.protection.branchPolicy == .allBranches)
    #expect(staging.createdAt == nil)
    #expect(staging.updatedAt == nil)

    let request = try #require(await transport.recordedRequests().first)
    #expect(request.httpMethod == "GET")
    #expect(request.url?.path == "/repos/octocat/project/environments")
    #expect(queryValue("per_page", in: request) == "100")
    #expect(queryValue("page", in: request) == "1")
    #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer ghu_environment")
    #expect(request.value(forHTTPHeaderField: "Accept") == "application/vnd.github+json")
    #expect(
        request.value(forHTTPHeaderField: "X-GitHub-Api-Version")
            == GitHubRESTAPIVersionPolicy.currentVersion
    )
}

@Test
func environmentClientClampsLimitsToOneAndOneHundred() async throws {
    let transport = EnvironmentQueueTransport([
        EnvironmentStubResponse(#"{"total_count":0,"environments":[]}"#),
        EnvironmentStubResponse(#"{"total_count":0,"environments":[]}"#),
    ])
    let client = GitHubEnvironmentClient(transport: transport)

    _ = try await client.environments(
        repository: environmentRepository(),
        connection: environmentGitHubDotComConnection(),
        credential: GitHubCredential(accessToken: "ghu_environment"),
        limit: 0
    )
    _ = try await client.environments(
        repository: environmentRepository(),
        connection: environmentGitHubDotComConnection(),
        credential: GitHubCredential(accessToken: "ghu_environment"),
        limit: 500
    )

    let requests = await transport.recordedRequests()
    #expect(requests.count == 2)
    #expect(queryValue("per_page", in: requests[0]) == "1")
    #expect(queryValue("page", in: requests[0]) == "1")
    #expect(queryValue("per_page", in: requests[1]) == "100")
    #expect(queryValue("page", in: requests[1]) == "1")
}

@Test
func environmentClientRejectsInvalidInputBeforeNetwork() async throws {
    let transport = EnvironmentQueueTransport([])
    let client = GitHubEnvironmentClient(transport: transport)

    await #expect(throws: GitHubEnvironmentClientError.invalidCredential) {
        _ = try await client.environments(
            repository: environmentRepository(),
            connection: environmentGitHubDotComConnection(),
            credential: GitHubCredential(accessToken: "   ")
        )
    }

    await #expect(throws: GitHubEnvironmentClientError.invalidRepository) {
        _ = try await client.environments(
            repository: environmentRepository(owner: "", name: ""),
            connection: environmentGitHubDotComConnection(),
            credential: GitHubCredential(accessToken: "ghu_environment")
        )
    }

    #expect(await transport.recordedRequests().isEmpty)
}

@Test(arguments: [
    #"{"total_count":-1,"environments":[]}"#,
    #"{"total_count":0,"environments":[{"id":101,"name":"production","protection_rules":[],"deployment_branch_policy":null}]}"#,
    #"{"total_count":1,"environments":[{"id":0,"name":"production","protection_rules":[],"deployment_branch_policy":null}]}"#,
    #"{"total_count":1,"environments":[{"id":101,"name":"   ","protection_rules":[],"deployment_branch_policy":null}]}"#,
    #"{"total_count":1,"environments":[{"id":101,"name":"production","protection_rules":[{"type":"wait_timer","wait_timer":10},{"type":"wait_timer","wait_timer":20}],"deployment_branch_policy":null}]}"#,
    #"{"total_count":1,"environments":[{"id":101,"name":"production","protection_rules":[{"type":"required_reviewers","reviewers":[]},{"type":"required_reviewers","reviewers":[]}],"deployment_branch_policy":null}]}"#,
    #"{"total_count":1,"environments":[{"id":101,"name":"production","protection_rules":[{"type":"wait_timer","wait_timer":-1}],"deployment_branch_policy":null}]}"#,
])
func environmentClientRejectsMalformedCatalogPayload(json: String) async throws {
    let client = GitHubEnvironmentClient(
        transport: EnvironmentQueueTransport([EnvironmentStubResponse(json)])
    )

    await #expect(throws: GitHubEnvironmentClientError.invalidResponse) {
        _ = try await client.environments(
            repository: environmentRepository(),
            connection: environmentGitHubDotComConnection(),
            credential: GitHubCredential(accessToken: "ghu_environment")
        )
    }
}

@Test
func environmentClientMarksFirstPageAsTruncatedWithoutPagination() async throws {
    let entries = (1 ... 100)
        .map {
            #"{"id":#($0),"name":"env-#($0)","protection_rules":[],"deployment_branch_policy":null}"#
        }
        .joined(separator: ",")
    let json = #"{"total_count":101,"environments":[#(entries)]}"#
    let transport = EnvironmentQueueTransport([EnvironmentStubResponse(json)])
    let client = GitHubEnvironmentClient(transport: transport)

    let catalog = try await client.environments(
        repository: environmentRepository(),
        connection: environmentGitHubDotComConnection(),
        credential: GitHubCredential(accessToken: "ghu_environment")
    )

    #expect(catalog.totalCount == 101)
    #expect(catalog.environments.count == 100)
    #expect(catalog.isTruncated)
    #expect(await transport.recordedRequests().count == 1)
}

@Test(arguments: [
    (#""deployment_branch_policy":null"#, GitHubEnvironmentBranchPolicy.allBranches),
    ("", GitHubEnvironmentBranchPolicy.unknown),
    (#""deployment_branch_policy":{"protected_branches":true,"custom_branch_policies":false}"#, GitHubEnvironmentBranchPolicy.protectedBranches),
    (#""deployment_branch_policy":{"protected_branches":false,"custom_branch_policies":true}"#, GitHubEnvironmentBranchPolicy.customBranches),
    (#""deployment_branch_policy":{"protected_branches":true,"custom_branch_policies":true}"#, GitHubEnvironmentBranchPolicy.unknown),
    (#""deployment_branch_policy":{"protected_branches":false,"custom_branch_policies":false}"#, GitHubEnvironmentBranchPolicy.unknown),
])
func environmentClientDistinguishesBranchPolicyPresence(
    fragment: String,
    expected: GitHubEnvironmentBranchPolicy
) async throws {
    let suffix = fragment.isEmpty ? "" : ",\(fragment)"
    let json = """
    {
      "total_count":1,
      "environments":[
        {
          "id":101,
          "name":"production",
          "protection_rules":[]
          \(suffix)
        }
      ]
    }
    """
    let client = GitHubEnvironmentClient(
        transport: EnvironmentQueueTransport([EnvironmentStubResponse(json)])
    )

    let catalog = try await client.environments(
        repository: environmentRepository(),
        connection: environmentGitHubDotComConnection(),
        credential: GitHubCredential(accessToken: "ghu_environment")
    )

    #expect(catalog.environments.first?.protection.branchPolicy == expected)
}

@Test
func environmentClientIgnoresUnknownRulesAndPreservesZeroValues() async throws {
    let json = """
    {
      "total_count":1,
      "environments":[
        {
          "id":101,
          "name":"production",
          "protection_rules":[
            {"type":"future_rule","future_secret":"must-not-surface"},
            {"type":"required_reviewers","prevent_self_review":false,"reviewers":[]},
            {"type":"wait_timer","wait_timer":0}
          ],
          "deployment_branch_policy":null
        }
      ]
    }
    """
    let client = GitHubEnvironmentClient(
        transport: EnvironmentQueueTransport([EnvironmentStubResponse(json)])
    )

    let catalog = try await client.environments(
        repository: environmentRepository(),
        connection: environmentGitHubDotComConnection(),
        credential: GitHubCredential(accessToken: "ghu_environment")
    )
    let environment = try #require(catalog.environments.first)

    #expect(environment.protection.waitTimerMinutes == 0)
    #expect(environment.protection.requiredReviewerCount == 0)
    #expect(environment.protection.preventsSelfReview == false)
}

@Test
func environmentClientUsesExplicitGHESVersionAndCustomPort() async throws {
    let transport = EnvironmentQueueTransport([
        EnvironmentStubResponse(#"{"total_count":0,"environments":[]}"#),
    ])
    let client = GitHubEnvironmentClient(transport: transport)
    var connection = GitHubConnection(
        displayName: "Internal GitHub",
        deploymentKind: .enterpriseServer,
        webBaseURL: try #require(URL(string: "https://github.internal.example:8443"))
    )
    connection.apiVersion = "2022-11-28"

    _ = try await client.environments(
        repository: environmentRepository(
            owner: "acme",
            name: "service-api",
            webBaseURL: "https://github.internal.example:8443"
        ),
        connection: connection,
        credential: GitHubCredential(accessToken: "ghu_enterprise")
    )

    let request = try #require(await transport.recordedRequests().first)
    #expect(request.url?.host == "github.internal.example")
    #expect(request.url?.port == 8443)
    #expect(request.url?.path == "/api/v3/repos/acme/service-api/environments")
    #expect(request.value(forHTTPHeaderField: "X-GitHub-Api-Version") == "2022-11-28")
}

@Test
func environmentClientOmitsVersionForUnversionedGHES() async throws {
    let transport = EnvironmentQueueTransport([
        EnvironmentStubResponse(#"{"total_count":0,"environments":[]}"#),
    ])
    let client = GitHubEnvironmentClient(transport: transport)
    let connection = GitHubConnection(
        displayName: "Internal GitHub",
        deploymentKind: .enterpriseServer,
        webBaseURL: try #require(URL(string: "https://github.internal.example"))
    )

    _ = try await client.environments(
        repository: environmentRepository(
            owner: "acme",
            name: "service-api",
            webBaseURL: "https://github.internal.example"
        ),
        connection: connection,
        credential: GitHubCredential(accessToken: "ghu_enterprise")
    )

    let request = try #require(await transport.recordedRequests().first)
    #expect(request.value(forHTTPHeaderField: "X-GitHub-Api-Version") == nil)
}

@Test
func environmentClientUsesCurrentVersionForGHEDotCom() async throws {
    let transport = EnvironmentQueueTransport([
        EnvironmentStubResponse(#"{"total_count":0,"environments":[]}"#),
    ])
    let client = GitHubEnvironmentClient(transport: transport)
    let connection = GitHubConnection(
        displayName: "GHE.com",
        deploymentKind: .gheDotCom,
        webBaseURL: try #require(URL(string: "https://octocat.ghe.com"))
    )

    _ = try await client.environments(
        repository: environmentRepository(
            owner: "octocat",
            name: "project",
            webBaseURL: "https://octocat.ghe.com"
        ),
        connection: connection,
        credential: GitHubCredential(accessToken: "ghu_ghe")
    )

    let request = try #require(await transport.recordedRequests().first)
    #expect(
        request.value(forHTTPHeaderField: "X-GitHub-Api-Version")
            == GitHubRESTAPIVersionPolicy.currentVersion
    )
}

@Test
func environmentClientSurfacesHTTPStatus() async throws {
    let client = GitHubEnvironmentClient(
        transport: EnvironmentQueueTransport([
            EnvironmentStubResponse(#"{"message":"Forbidden"}"#, statusCode: 403),
        ])
    )

    await #expect(throws: GitHubEnvironmentClientError.httpStatus(403)) {
        _ = try await client.environments(
            repository: environmentRepository(),
            connection: environmentGitHubDotComConnection(),
            credential: GitHubCredential(accessToken: "ghu_environment")
        )
    }
}

private func environmentGitHubDotComConnection() throws -> GitHubConnection {
    GitHubConnection(
        displayName: "GitHub.com",
        deploymentKind: .githubDotCom,
        webBaseURL: try #require(URL(string: "https://github.com"))
    )
}

private func environmentRepository(
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

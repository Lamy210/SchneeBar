import Foundation
import SchneeBarGitHub
import Testing

private struct DeploymentStubResponse: Sendable {
    let json: String
    let statusCode: Int

    init(_ json: String, statusCode: Int = 200) {
        self.json = json
        self.statusCode = statusCode
    }
}

private actor DeploymentQueueTransport: GitHubHTTPTransport {
    private var responses: [DeploymentStubResponse]
    private var requests: [URLRequest] = []

    init(_ responses: [DeploymentStubResponse]) {
        self.responses = responses
    }

    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        requests.append(request)
        let response = responses.isEmpty
            ? DeploymentStubResponse(#"{"message":"Unexpected request"}"#, statusCode: 500)
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
func deploymentClientLoadsExactSHAFirstPageOnly() async throws {
    let transport = DeploymentQueueTransport([
        DeploymentStubResponse(
            #"[{"id":901,"sha":"LANDED-SHA","environment":"production","production_environment":true,"transient_environment":false,"created_at":"2026-09-18T00:00:00Z","updated_at":"2026-09-18T00:01:00Z"}]"#
        ),
    ])
    let client = GitHubDeploymentClient(transport: transport)

    let deployments = try await client.deployments(
        sha: " landed-sha ",
        repository: try deploymentRepository(),
        connection: try deploymentGitHubDotComConnection(),
        credential: GitHubCredential(accessToken: "ghu_deploy"),
        limit: 100
    )

    #expect(deployments.count == 1)
    #expect(deployments[0].id == 901)
    #expect(deployments[0].sha == "landed-sha")
    #expect(deployments[0].environment == "production")
    #expect(deployments[0].isProductionEnvironment)
    #expect(!deployments[0].isTransientEnvironment)
    #expect(deployments[0].createdAt != nil)
    #expect(deployments[0].updatedAt != nil)

    let requests = await transport.recordedRequests()
    #expect(requests.count == 1)
    let request = try #require(requests.first)
    #expect(request.httpMethod == "GET")
    #expect(request.url?.path == "/repos/octocat/project/deployments")
    #expect(queryValue("sha", in: request) == "landed-sha")
    #expect(queryValue("per_page", in: request) == "20")
    #expect(queryValue("page", in: request) == "1")
    #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer ghu_deploy")
    #expect(request.value(forHTTPHeaderField: "Accept") == "application/vnd.github+json")
    #expect(
        request.value(forHTTPHeaderField: "X-GitHub-Api-Version")
            == GitHubRESTAPIVersionPolicy.currentVersion
    )
}

@Test
func deploymentClientClampsMinimumLimitToOne() async throws {
    let transport = DeploymentQueueTransport([
        DeploymentStubResponse("[]"),
    ])
    let client = GitHubDeploymentClient(transport: transport)

    _ = try await client.deployments(
        sha: "landed-sha",
        repository: try deploymentRepository(),
        connection: try deploymentGitHubDotComConnection(),
        credential: GitHubCredential(accessToken: "ghu_deploy"),
        limit: 0
    )

    let request = try #require(await transport.recordedRequests().first)
    #expect(queryValue("per_page", in: request) == "1")
    #expect(queryValue("page", in: request) == "1")
}

@Test
func deploymentClientRejectsMismatchedDeploymentSHA() async throws {
    let transport = DeploymentQueueTransport([
        DeploymentStubResponse(
            #"[{"id":901,"sha":"other-sha","environment":"production","production_environment":true,"transient_environment":false,"created_at":"2026-09-18T00:00:00Z","updated_at":"2026-09-18T00:01:00Z"}]"#
        ),
    ])
    let client = GitHubDeploymentClient(transport: transport)

    await #expect(throws: GitHubDeploymentClientError.invalidResponse) {
        _ = try await client.deployments(
            sha: "landed-sha",
            repository: deploymentRepository(),
            connection: deploymentGitHubDotComConnection(),
            credential: GitHubCredential(accessToken: "ghu_deploy")
        )
    }
}

@Test
func deploymentClientLoadsLatestStatusAndSanitizesExternalURLs() async throws {
    let transport = DeploymentQueueTransport([
        DeploymentStubResponse(
            #"[{"id":1001,"state":"success","environment":"production","description":"Deployed","environment_url":"https://deploy.example.test/production","log_url":"https://deploy.example.test/logs/1001","created_at":"2026-09-18T00:00:00Z","updated_at":"2026-09-18T00:01:00Z"}]"#
        ),
    ])
    let client = GitHubDeploymentClient(transport: transport)

    let status = try #require(
        try await client.latestStatus(
            deploymentID: 901,
            repository: deploymentRepository(),
            connection: deploymentGitHubDotComConnection(),
            credential: GitHubCredential(accessToken: "ghu_deploy")
        )
    )

    #expect(status.id == 1001)
    #expect(status.state == .success)
    #expect(status.environment == "production")
    #expect(status.description == "Deployed")
    #expect(status.environmentURL?.absoluteString == "https://deploy.example.test/production")
    #expect(status.logURL?.absoluteString == "https://deploy.example.test/logs/1001")
    #expect(status.createdAt != nil)
    #expect(status.updatedAt != nil)

    let requests = await transport.recordedRequests()
    #expect(requests.count == 1)
    let request = try #require(requests.first)
    #expect(request.url?.path == "/repos/octocat/project/deployments/901/statuses")
    #expect(queryValue("per_page", in: request) == "1")
    #expect(queryValue("page", in: request) == "1")
}

@Test
func deploymentClientPreservesUnknownStatusState() async throws {
    let transport = DeploymentQueueTransport([
        DeploymentStubResponse(
            #"[{"id":1001,"state":"future_state","environment":"preview","description":null,"environment_url":null,"log_url":null,"created_at":"2026-09-18T00:00:00Z","updated_at":"2026-09-18T00:01:00Z"}]"#
        ),
    ])
    let client = GitHubDeploymentClient(transport: transport)

    let status = try #require(
        try await client.latestStatus(
            deploymentID: 901,
            repository: deploymentRepository(),
            connection: deploymentGitHubDotComConnection(),
            credential: GitHubCredential(accessToken: "ghu_deploy")
        )
    )

    #expect(status.state == .unknown("future_state"))
}

@Test
func deploymentClientDropsUnsafeStatusURLs() async throws {
    let unsafePairs: [(String, String)] = [
        ("http://deploy.example.test/production", "http://deploy.example.test/logs/1"),
        ("https://user:pass@deploy.example.test/production", "https://user:pass@deploy.example.test/logs/1"),
        ("https:///missing-host", "https:///missing-host"),
        ("relative/path", "logs/relative"),
    ]

    for (environmentURL, logURL) in unsafePairs {
        let json = """
        [{"id":1001,"state":"success","environment":"production","description":"Deployed","environment_url":"\(environmentURL)","log_url":"\(logURL)","created_at":"2026-09-18T00:00:00Z","updated_at":"2026-09-18T00:01:00Z"}]
        """
        let transport = DeploymentQueueTransport([DeploymentStubResponse(json)])
        let client = GitHubDeploymentClient(transport: transport)

        let status = try #require(
            try await client.latestStatus(
                deploymentID: 901,
                repository: deploymentRepository(),
                connection: deploymentGitHubDotComConnection(),
                credential: GitHubCredential(accessToken: "ghu_deploy")
            )
        )

        #expect(status.environmentURL == nil)
        #expect(status.logURL == nil)
    }
}

@Test
func deploymentClientReturnsNilWhenNoStatusExists() async throws {
    let transport = DeploymentQueueTransport([
        DeploymentStubResponse("[]"),
    ])
    let client = GitHubDeploymentClient(transport: transport)

    let status = try await client.latestStatus(
        deploymentID: 901,
        repository: deploymentRepository(),
        connection: deploymentGitHubDotComConnection(),
        credential: GitHubCredential(accessToken: "ghu_deploy")
    )

    #expect(status == nil)
}

@Test
func deploymentClientRejectsInvalidInputBeforeNetwork() async throws {
    let transport = DeploymentQueueTransport([])
    let client = GitHubDeploymentClient(transport: transport)

    await #expect(throws: GitHubDeploymentClientError.invalidSHA) {
        _ = try await client.deployments(
            sha: "   ",
            repository: deploymentRepository(),
            connection: deploymentGitHubDotComConnection(),
            credential: GitHubCredential(accessToken: "ghu_deploy")
        )
    }

    await #expect(throws: GitHubDeploymentClientError.invalidCredential) {
        _ = try await client.deployments(
            sha: "landed-sha",
            repository: deploymentRepository(),
            connection: deploymentGitHubDotComConnection(),
            credential: GitHubCredential(accessToken: "   ")
        )
    }

    await #expect(throws: GitHubDeploymentClientError.invalidRepository) {
        _ = try await client.deployments(
            sha: "landed-sha",
            repository: deploymentRepository(owner: "", name: ""),
            connection: deploymentGitHubDotComConnection(),
            credential: GitHubCredential(accessToken: "ghu_deploy")
        )
    }

    await #expect(throws: GitHubDeploymentClientError.invalidDeploymentID) {
        _ = try await client.latestStatus(
            deploymentID: 0,
            repository: deploymentRepository(),
            connection: deploymentGitHubDotComConnection(),
            credential: GitHubCredential(accessToken: "ghu_deploy")
        )
    }

    #expect(await transport.recordedRequests().isEmpty)
}

@Test
func deploymentClientUsesExplicitGHESVersionAndCustomPort() async throws {
    let transport = DeploymentQueueTransport([
        DeploymentStubResponse("[]"),
    ])
    let client = GitHubDeploymentClient(transport: transport)
    var connection = GitHubConnection(
        displayName: "Internal GitHub",
        deploymentKind: .enterpriseServer,
        webBaseURL: try #require(URL(string: "https://github.internal.example:8443"))
    )
    connection.apiVersion = "2022-11-28"

    _ = try await client.deployments(
        sha: "landed-sha",
        repository: deploymentRepository(
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
    #expect(request.url?.path == "/api/v3/repos/acme/service-api/deployments")
    #expect(request.value(forHTTPHeaderField: "X-GitHub-Api-Version") == "2022-11-28")
}

@Test
func deploymentClientOmitsVersionForUnversionedGHES() async throws {
    let transport = DeploymentQueueTransport([
        DeploymentStubResponse("[]"),
    ])
    let client = GitHubDeploymentClient(transport: transport)
    let connection = GitHubConnection(
        displayName: "Internal GitHub",
        deploymentKind: .enterpriseServer,
        webBaseURL: try #require(URL(string: "https://github.internal.example"))
    )

    _ = try await client.deployments(
        sha: "landed-sha",
        repository: deploymentRepository(
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
func deploymentClientSurfacesHTTPStatus() async throws {
    let transport = DeploymentQueueTransport([
        DeploymentStubResponse(#"{"message":"Forbidden"}"#, statusCode: 403),
    ])
    let client = GitHubDeploymentClient(transport: transport)

    await #expect(throws: GitHubDeploymentClientError.httpStatus(403)) {
        _ = try await client.deployments(
            sha: "landed-sha",
            repository: deploymentRepository(),
            connection: deploymentGitHubDotComConnection(),
            credential: GitHubCredential(accessToken: "ghu_deploy")
        )
    }
}

private func deploymentGitHubDotComConnection() throws -> GitHubConnection {
    GitHubConnection(
        displayName: "GitHub.com",
        deploymentKind: .githubDotCom,
        webBaseURL: try #require(URL(string: "https://github.com"))
    )
}

private func deploymentRepository(
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

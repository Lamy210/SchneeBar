import Foundation
import SchneeBarGitHub
import Testing

private struct AccessStubResponse: Sendable {
    let json: String
    let statusCode: Int

    init(_ json: String, statusCode: Int = 200) {
        self.json = json
        self.statusCode = statusCode
    }
}

private actor AccessQueueTransport: GitHubHTTPTransport {
    private var responses: [AccessStubResponse]
    private var requests: [URLRequest] = []

    init(_ responses: [AccessStubResponse]) {
        self.responses = responses
    }

    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        requests.append(request)
        let response = responses.isEmpty
            ? AccessStubResponse("{}", statusCode: 500)
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
func loadsAuthenticatedAccountWithHostedAPIHeaders() async throws {
    let transport = AccessQueueTransport([
        AccessStubResponse(
            #"{"id":90091196,"login":"Lamy210","name":"Lamy","avatar_url":"https://avatars.example/lamy.png"}"#
        )
    ])
    let client = GitHubAccessClient(transport: transport)

    let account = try await client.authenticatedAccount(
        connection: try githubDotComAccessConnection(),
        credential: GitHubCredential(accessToken: "ghu_access")
    )

    #expect(account.identity.id == "90091196")
    #expect(account.identity.login == "Lamy210")
    #expect(account.displayName == "Lamy")

    let request = try #require(await transport.recordedRequests().last)
    #expect(request.url?.absoluteString == "https://api.github.com/user")
    #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer ghu_access")
    #expect(request.value(forHTTPHeaderField: "Accept") == "application/vnd.github+json")
    #expect(request.value(forHTTPHeaderField: "X-GitHub-Api-Version") == "2026-03-10")
}

@Test
func paginatesAccessibleInstallationsAndPreservesPermissions() async throws {
    let transport = AccessQueueTransport([
        AccessStubResponse(
            #"{"total_count":2,"installations":[{"id":11,"account":{"id":101,"login":"Lamy210","type":"User"},"repository_selection":"selected","permissions":{"actions":"read","pull_requests":"read"},"suspended_at":null}]}"#
        ),
        AccessStubResponse(
            #"{"total_count":2,"installations":[{"id":22,"account":{"id":202,"login":"acme","type":"Organization"},"repository_selection":"all","permissions":{"actions":"read"},"suspended_at":"2026-09-01T00:00:00Z"}]}"#
        ),
    ])
    let client = GitHubAccessClient(transport: transport)

    let installations = try await client.installations(
        connection: try githubDotComAccessConnection(),
        credential: GitHubCredential(accessToken: "ghu_access")
    )

    #expect(installations.map(\.id) == [11, 22])
    #expect(installations[0].permissions["actions"] == "read")
    #expect(!installations[0].isSuspended)
    #expect(installations[1].isSuspended)

    let requests = await transport.recordedRequests()
    #expect(requests.count == 2)
    #expect(queryValue("page", in: requests[0]) == "1")
    #expect(queryValue("per_page", in: requests[0]) == "100")
    #expect(queryValue("page", in: requests[1]) == "2")
}

@Test
func loadsRepositoriesFromCustomPortGHESWithoutTrustingResponseWebURLs() async throws {
    let transport = AccessQueueTransport([
        AccessStubResponse(
            #"{"total_count":1,"repositories":[{"id":42,"name":"service-api","full_name":"acme/service-api","private":true,"owner":{"id":202,"login":"acme","type":"Organization"},"permissions":{"admin":false,"maintain":true,"push":true,"triage":true,"pull":true}}]}"#
        )
    ])
    let client = GitHubAccessClient(transport: transport)
    let connection = GitHubConnection(
        displayName: "Internal GitHub",
        deploymentKind: .enterpriseServer,
        webBaseURL: try #require(URL(string: "https://github.internal.example:8443"))
    )

    let repositories = try await client.repositories(
        installationID: 99,
        connection: connection,
        credential: GitHubCredential(accessToken: "ghu_enterprise")
    )

    let repository = try #require(repositories.first)
    #expect(repository.fullName == "acme/service-api")
    #expect(repository.webURL.absoluteString == "https://github.internal.example:8443/acme/service-api")
    #expect(repository.permissions.maintain)
    #expect(repository.permissions.push)

    let request = try #require(await transport.recordedRequests().last)
    #expect(request.url?.path == "/api/v3/user/installations/99/repositories")
    #expect(request.url?.host == "github.internal.example")
    #expect(request.url?.port == 8443)
    #expect(request.value(forHTTPHeaderField: "X-GitHub-Api-Version") == nil)
}

@Test
func usesExplicitAPIVersionForGHESWhenNegotiated() async throws {
    let transport = AccessQueueTransport([
        AccessStubResponse(#"{"id":1,"login":"octocat","name":null,"avatar_url":null}"#)
    ])
    let client = GitHubAccessClient(transport: transport)
    var connection = GitHubConnection(
        displayName: "Internal GitHub",
        deploymentKind: .enterpriseServer,
        webBaseURL: try #require(URL(string: "https://github.internal.example"))
    )
    connection.apiVersion = "2022-11-28"

    _ = try await client.authenticatedAccount(
        connection: connection,
        credential: GitHubCredential(accessToken: "ghu_enterprise")
    )

    let request = try #require(await transport.recordedRequests().last)
    #expect(request.value(forHTTPHeaderField: "X-GitHub-Api-Version") == "2022-11-28")
}

@Test
func inventoryAssociatesRepositoriesWithEachInstallation() async throws {
    let transport = AccessQueueTransport([
        AccessStubResponse(#"{"id":1,"login":"octocat","name":"Octo Cat","avatar_url":null}"#),
        AccessStubResponse(
            #"{"total_count":1,"installations":[{"id":5,"account":{"id":10,"login":"octocat","type":"User"},"repository_selection":"selected","permissions":{"actions":"read"},"suspended_at":null}]}"#
        ),
        AccessStubResponse(
            #"{"total_count":1,"repositories":[{"id":77,"name":"project","full_name":"octocat/project","private":false,"owner":{"id":10,"login":"octocat","type":"User"},"permissions":{"admin":true,"maintain":true,"push":true,"triage":true,"pull":true}}]}"#
        ),
    ])
    let client = GitHubAccessClient(transport: transport)

    let inventory = try await client.inventory(
        connection: try githubDotComAccessConnection(),
        credential: GitHubCredential(accessToken: "ghu_access")
    )

    #expect(inventory.account.identity.login == "octocat")
    #expect(inventory.installations.count == 1)
    #expect(inventory.installations[0].installation.id == 5)
    #expect(inventory.installations[0].status == .available)
    #expect(inventory.installations[0].repositories.map(\.fullName) == ["octocat/project"])
}

@Test
func inventorySkipsRepositoryRequestForSuspendedInstallation() async throws {
    let transport = AccessQueueTransport([
        AccessStubResponse(#"{"id":1,"login":"octocat","name":null,"avatar_url":null}"#),
        AccessStubResponse(
            #"{"total_count":1,"installations":[{"id":5,"account":{"id":10,"login":"octocat","type":"User"},"repository_selection":"selected","permissions":{"actions":"read"},"suspended_at":"2026-09-01T00:00:00Z"}]}"#
        ),
    ])
    let client = GitHubAccessClient(transport: transport)

    let inventory = try await client.inventory(
        connection: try githubDotComAccessConnection(),
        credential: GitHubCredential(accessToken: "ghu_access")
    )

    #expect(inventory.installations[0].status == .suspended)
    #expect(inventory.installations[0].repositories.isEmpty)
    #expect(await transport.recordedRequests().count == 2)
}

@Test
func inventoryKeepsForbiddenInstallationWithoutFailingWholeConnection() async throws {
    let transport = AccessQueueTransport([
        AccessStubResponse(#"{"id":1,"login":"octocat","name":null,"avatar_url":null}"#),
        AccessStubResponse(
            #"{"total_count":1,"installations":[{"id":5,"account":{"id":10,"login":"octocat","type":"User"},"repository_selection":"selected","permissions":{"actions":"read"},"suspended_at":null}]}"#
        ),
        AccessStubResponse(#"{"message":"Forbidden"}"#, statusCode: 403),
    ])
    let client = GitHubAccessClient(transport: transport)

    let inventory = try await client.inventory(
        connection: try githubDotComAccessConnection(),
        credential: GitHubCredential(accessToken: "ghu_access")
    )

    #expect(inventory.installations[0].status == .forbidden)
    #expect(inventory.installations[0].repositories.isEmpty)
}

@Test
func inventoryPropagatesRepository401AsConnectionAuthenticationFailure() async throws {
    let transport = AccessQueueTransport([
        AccessStubResponse(#"{"id":1,"login":"octocat","name":null,"avatar_url":null}"#),
        AccessStubResponse(
            #"{"total_count":1,"installations":[{"id":5,"account":{"id":10,"login":"octocat","type":"User"},"repository_selection":"selected","permissions":{"actions":"read"},"suspended_at":null}]}"#
        ),
        AccessStubResponse(#"{"message":"Bad credentials"}"#, statusCode: 401),
    ])
    let client = GitHubAccessClient(transport: transport)

    await #expect(throws: GitHubAccessClientError.httpStatus(401)) {
        try await client.inventory(
            connection: try githubDotComAccessConnection(),
            credential: GitHubCredential(accessToken: "expired")
        )
    }
}

@Test
func emptyAccessTokenStopsBeforeNetworkRequest() async throws {
    let transport = AccessQueueTransport([])
    let client = GitHubAccessClient(transport: transport)

    await #expect(throws: GitHubAccessClientError.invalidCredential) {
        try await client.authenticatedAccount(
            connection: try githubDotComAccessConnection(),
            credential: GitHubCredential(accessToken: "   ")
        )
    }

    #expect(await transport.recordedRequests().isEmpty)
}

@Test
func mapsHTTPAuthenticationFailure() async throws {
    let transport = AccessQueueTransport([
        AccessStubResponse(#"{"message":"Bad credentials"}"#, statusCode: 401)
    ])
    let client = GitHubAccessClient(transport: transport)

    await #expect(throws: GitHubAccessClientError.httpStatus(401)) {
        try await client.authenticatedAccount(
            connection: try githubDotComAccessConnection(),
            credential: GitHubCredential(accessToken: "expired")
        )
    }
}

@Test
func repeatedPaginationPageDoesNotLoopForever() async throws {
    let repeated = #"{"total_count":2,"installations":[{"id":11,"account":{"id":101,"login":"Lamy210","type":"User"},"repository_selection":"selected","permissions":{},"suspended_at":null}]}"#
    let transport = AccessQueueTransport([
        AccessStubResponse(repeated),
        AccessStubResponse(repeated),
    ])
    let client = GitHubAccessClient(transport: transport)

    let installations = try await client.installations(
        connection: try githubDotComAccessConnection(),
        credential: GitHubCredential(accessToken: "ghu_access")
    )

    #expect(installations.map(\.id) == [11])
    #expect(await transport.recordedRequests().count == 2)
}

private func githubDotComAccessConnection() throws -> GitHubConnection {
    GitHubConnection(
        displayName: "GitHub.com",
        deploymentKind: .githubDotCom,
        webBaseURL: try #require(URL(string: "https://github.com"))
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

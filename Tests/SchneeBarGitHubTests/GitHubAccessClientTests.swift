import Foundation
import SchneeBarGitHub
import Testing

private struct AccessStubResponse: Sendable {
    let json: String
    let statusCode: Int
    let headers: [String: String]

    init(
        _ json: String,
        statusCode: Int = 200,
        headers: [String: String] = [:]
    ) {
        self.json = json
        self.statusCode = statusCode
        self.headers = headers
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
                headerFields: response.headers
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
    #expect(request.value(forHTTPHeaderField: "User-Agent") == "SchneeBar")
    #expect(request.value(forHTTPHeaderField: "X-GitHub-Api-Version") == "2026-03-10")
}

@Test
func authenticatedAccountRejectsUnsafeLoginPresentationContent() async throws {
    let unsafeLogins = [
        "octo\\ncat",
        "octo\u{202E}cat",
        "octo\u{200B}cat",
        "octo\u{2028}cat",
        "octo\u{2029}cat",
        " octocat",
        String(
            repeating: "a",
            count:
                GitHubAccountIdentityPolicy.maximumLoginCharacters + 1
        ),
    ]

    for escapedLogin in unsafeLogins {
        let loginJSON: String
        if escapedLogin == "octo\\ncat" {
            loginJSON = #"octo\ncat"#
        } else {
            loginJSON = escapedLogin
        }

        let transport = AccessQueueTransport([
            AccessStubResponse(
                "{\"id\":42,\"login\":\"\(loginJSON)\",\"name\":null,\"avatar_url\":null}"
            )
        ])
        let client = GitHubAccessClient(transport: transport)

        await #expect(
            throws: GitHubAccessClientError.invalidResponse
        ) {
            try await client.authenticatedAccount(
                connection: try githubDotComAccessConnection(),
                credential: GitHubCredential(
                    accessToken: "ghu_access"
                )
            )
        }
    }
}

@Test
func accountLoginPolicyRejectsInvisibleAndDirectionalFormatting() {
    #expect(
        !GitHubAccountIdentityPolicy.isValidLogin(
            "octo\u{202E}cat"
        )
    )
    #expect(
        !GitHubAccountIdentityPolicy.isValidLogin(
            "octo\u{200B}cat"
        )
    )
    #expect(
        !GitHubAccountIdentityPolicy.isValidLogin(
            "octo\u{2028}cat"
        )
    )
    #expect(
        !GitHubAccountIdentityPolicy.isValidLogin(
            "octo\u{2029}cat"
        )
    )
}

@Test
func accountLoginPolicyDoesNotAssumeGitHubUsernameSyntax() {
    #expect(
        GitHubAccountIdentityPolicy.isValidLogin(
            "managed_user.enterprise-01"
        )
    )
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
func derivesAPIVersionForGHESWhenPersistedHeaderIsMissing() async throws {
    let transport = AccessQueueTransport([
        AccessStubResponse(
            #"{"id":1,"login":"octocat","name":null,"avatar_url":null}"#
        )
    ])
    let client = GitHubAccessClient(transport: transport)
    var connection = GitHubConnection(
        displayName: "Internal GitHub",
        deploymentKind: .enterpriseServer,
        webBaseURL: try #require(URL(string: "https://github.internal.example")),
        serverVersion: "3.20.9"
    )
    connection.apiVersion = nil

    _ = try await client.authenticatedAccount(
        connection: connection,
        credential: GitHubCredential(accessToken: "ghu_enterprise")
    )

    let request = try #require(await transport.recordedRequests().last)
    #expect(
        request.value(forHTTPHeaderField: "X-GitHub-Api-Version")
            == GitHubRESTAPIVersionPolicy.legacyVersion
    )
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

private func inventoryBudgetAccountResponse() -> AccessStubResponse {
    AccessStubResponse(
        #"{"id":1,"login":"octocat","name":null,"avatar_url":null}"#
    )
}

private func inventoryBudgetInstallationResponse(
    _ ids: [Int64]
) -> AccessStubResponse {
    let objects = ids.map { id in
        #"{"id":\#(id),"account":{"id":10,"login":"octocat","type":"User"},"repository_selection":"selected","permissions":{"actions":"read"},"suspended_at":null}"#
    }.joined(separator: ",")
    return AccessStubResponse(
        #"{"total_count":\#(ids.count),"installations":[\#(objects)]}"#
    )
}

private func inventoryBudgetRepositoryResponse(
    _ ids: [Int64]
) -> AccessStubResponse {
    let objects = ids.map { id in
        #"{"id":\#(id),"name":"project-\#(id)","full_name":"octocat/project-\#(id)","private":false,"owner":{"id":10,"login":"octocat","type":"User"},"permissions":{"admin":false,"maintain":false,"push":false,"triage":false,"pull":true}}"#
    }.joined(separator: ",")
    return AccessStubResponse(
        #"{"total_count":\#(ids.count),"repositories":[\#(objects)]}"#
    )
}

@Test
func inventoryZeroRequestBudgetPreventsAllNetworkIO() async throws {
    let transport = AccessQueueTransport([
        inventoryBudgetAccountResponse(),
    ])
    let client = GitHubAccessClient(
        transport: transport,
        inventoryFetchLimits: .init(maximumRequests: 0, maximumItems: 10)
    )

    await #expect(
        throws: GitHubAccessClientError.inventoryRequestBudgetExceeded
    ) {
        try await client.inventory(
            connection: try githubDotComAccessConnection(),
            credential: GitHubCredential(accessToken: "ghu_access")
        )
    }
    #expect(await transport.recordedRequests().isEmpty)
}

@Test
func inventoryZeroItemBudgetAllowsOnlyEmptyInventories() async throws {
    let transport = AccessQueueTransport([
        inventoryBudgetAccountResponse(),
        inventoryBudgetInstallationResponse([]),
    ])
    let client = GitHubAccessClient(
        transport: transport,
        inventoryFetchLimits: .init(maximumRequests: 2, maximumItems: 0)
    )

    let inventory = try await client.inventory(
        connection: try githubDotComAccessConnection(),
        credential: GitHubCredential(accessToken: "ghu_access")
    )
    #expect(inventory.installations.isEmpty)
    #expect(await transport.recordedRequests().count == 2)
}

@Test
func inventoryCompletesAtExactRequestAndItemBudgets() async throws {
    let transport = AccessQueueTransport([
        inventoryBudgetAccountResponse(),
        inventoryBudgetInstallationResponse([5]),
        inventoryBudgetRepositoryResponse([77]),
    ])
    let client = GitHubAccessClient(
        transport: transport,
        inventoryFetchLimits: .init(maximumRequests: 3, maximumItems: 2)
    )

    let inventory = try await client.inventory(
        connection: try githubDotComAccessConnection(),
        credential: GitHubCredential(accessToken: "ghu_access")
    )

    #expect(inventory.installations.count == 1)
    #expect(inventory.installations[0].status == .available)
    #expect(inventory.installations[0].repositories.map(\.id) == [77])
    #expect(await transport.recordedRequests().count == 3)
}

@Test
func ghesInventoryRequestBudgetStopsBeforeRepositoryDiscovery() async throws {
    let transport = AccessQueueTransport([
        inventoryBudgetAccountResponse(),
        inventoryBudgetInstallationResponse([5]),
    ])
    let client = GitHubAccessClient(
        transport: transport,
        inventoryFetchLimits: .init(maximumRequests: 2, maximumItems: 10)
    )
    let connection = GitHubConnection(
        displayName: "Internal GitHub",
        deploymentKind: .enterpriseServer,
        webBaseURL: try #require(
            URL(string: "https://github.internal.example:8443")
        )
    )

    await #expect(
        throws: GitHubAccessClientError.inventoryRequestBudgetExceeded
    ) {
        try await client.inventory(
            connection: connection,
            credential: GitHubCredential(accessToken: "ghu_enterprise")
        )
    }

    let requests = await transport.recordedRequests()
    #expect(requests.count == 2)
    #expect(requests[0].url?.path == "/api/v3/user")
    #expect(requests[1].url?.path == "/api/v3/user/installations")
    #expect(requests.allSatisfy { $0.url?.port == 8443 })
}

@Test
func inventoryRequestBudgetFailsClosedBeforeExtraRepositoryRequest() async throws {
    let transport = AccessQueueTransport([
        inventoryBudgetAccountResponse(),
        inventoryBudgetInstallationResponse([5, 6]),
        inventoryBudgetRepositoryResponse([]),
    ])
    let client = GitHubAccessClient(
        transport: transport,
        inventoryFetchLimits: .init(maximumRequests: 3, maximumItems: 10)
    )

    await #expect(
        throws: GitHubAccessClientError.inventoryRequestBudgetExceeded
    ) {
        try await client.inventory(
            connection: try githubDotComAccessConnection(),
            credential: GitHubCredential(accessToken: "ghu_access")
        )
    }

    // User + installations + first installation: no fourth HTTP request.
    #expect(await transport.recordedRequests().count == 3)
}

@Test
func inventoryItemBudgetFailsClosedAtInstallationPageBoundary() async throws {
    let transport = AccessQueueTransport([
        inventoryBudgetAccountResponse(),
        inventoryBudgetInstallationResponse([5, 6]),
    ])
    let client = GitHubAccessClient(
        transport: transport,
        inventoryFetchLimits: .init(maximumRequests: 10, maximumItems: 1)
    )

    await #expect(
        throws: GitHubAccessClientError.inventoryItemBudgetExceeded
    ) {
        try await client.inventory(
            connection: try githubDotComAccessConnection(),
            credential: GitHubCredential(accessToken: "ghu_access")
        )
    }
    #expect(await transport.recordedRequests().count == 2)
}

@Test
func inventoryItemBudgetIncludesRepositoriesAcrossInstallations() async throws {
    let transport = AccessQueueTransport([
        inventoryBudgetAccountResponse(),
        inventoryBudgetInstallationResponse([5, 6]),
        inventoryBudgetRepositoryResponse([77]),
        inventoryBudgetRepositoryResponse([88]),
    ])
    let client = GitHubAccessClient(
        transport: transport,
        inventoryFetchLimits: .init(maximumRequests: 10, maximumItems: 3)
    )

    await #expect(
        throws: GitHubAccessClientError.inventoryItemBudgetExceeded
    ) {
        try await client.inventory(
            connection: try githubDotComAccessConnection(),
            credential: GitHubCredential(accessToken: "ghu_access")
        )
    }

    // Two installation records plus the first repository consume all items.
    #expect(await transport.recordedRequests().count == 4)
}

@Test
func inventoryFailedRequestsCountTowardsGlobalRequestBudget() async throws {
    let transport = AccessQueueTransport([
        inventoryBudgetAccountResponse(),
        inventoryBudgetInstallationResponse([5, 6]),
        AccessStubResponse(#"{"message":"Forbidden"}"#, statusCode: 403),
    ])
    let client = GitHubAccessClient(
        transport: transport,
        inventoryFetchLimits: .init(maximumRequests: 3, maximumItems: 10)
    )

    await #expect(
        throws: GitHubAccessClientError.inventoryRequestBudgetExceeded
    ) {
        try await client.inventory(
            connection: try githubDotComAccessConnection(),
            credential: GitHubCredential(accessToken: "ghu_access")
        )
    }

    // A 403 consumes its request; the next installation must not be fetched.
    #expect(await transport.recordedRequests().count == 3)
}

private actor InventoryCancellationTransport: GitHubHTTPTransport {
    private var requestCount = 0

    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        requestCount += 1
        if requestCount == 3 {
            throw CancellationError()
        }
        let response = requestCount == 1
            ? inventoryBudgetAccountResponse()
            : inventoryBudgetInstallationResponse([5, 6])
        let httpResponse = try #require(
            HTTPURLResponse(
                url: request.url!,
                statusCode: response.statusCode,
                httpVersion: "HTTP/1.1",
                headerFields: response.headers
            )
        )
        return (Data(response.json.utf8), httpResponse)
    }

    func count() -> Int {
        requestCount
    }
}

@Test
func inventoryTransportCancellationDoesNotBecomeUnavailableStatus() async throws {
    let transport = InventoryCancellationTransport()
    let client = GitHubAccessClient(
        transport: transport,
        inventoryFetchLimits: .init(maximumRequests: 10, maximumItems: 10)
    )

    await #expect(throws: CancellationError.self) {
        try await client.inventory(
            connection: try githubDotComAccessConnection(),
            credential: GitHubCredential(accessToken: "ghu_access")
        )
    }

    #expect(await transport.count() == 3)
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
func preservesSafeSSORequiredResponseEvidenceWithoutRawURL() async throws {
    let transport = AccessQueueTransport([
        AccessStubResponse(
            #"{\"message\":\"SSO required\"}"#,
            statusCode: 403,
            headers: [
                "X-GitHub-SSO":
                    "required; url=https://github.com/orgs/acme/sso?authorization_request=sensitive"
            ]
        )
    ])
    let client = GitHubAccessClient(transport: transport)

    await #expect(
        throws: GitHubAccessClientError.httpFailure(
            GitHubHTTPFailureEvidence(
                statusCode: 403,
                ssoSignal: .required
            )
        )
    ) {
        try await client.authenticatedAccount(
            connection: try githubDotComAccessConnection(),
            credential: GitHubCredential(accessToken: "ghu_access")
        )
    }
}

@Test
func preservesUnknownSSOHeaderAsOpaqueSignal() async throws {
    let transport = AccessQueueTransport([
        AccessStubResponse(
            #"{\"message\":\"SSO policy\"}"#,
            statusCode: 403,
            headers: [
                "X-GitHub-SSO":
                    "future-directive; sensitive-field=must-not-be-retained"
            ]
        )
    ])
    let client = GitHubAccessClient(transport: transport)

    await #expect(
        throws: GitHubAccessClientError.httpFailure(
            GitHubHTTPFailureEvidence(
                statusCode: 403,
                ssoSignal: .other
            )
        )
    ) {
        try await client.authenticatedAccount(
            connection: try githubDotComAccessConnection(),
            credential: GitHubCredential(accessToken: "ghu_access")
        )
    }
}

@Test
func inventoryMarksExplicitSSORequired403Separately() async throws {
    let transport = AccessQueueTransport([
        AccessStubResponse(#"{"id":1,"login":"octocat","name":null,"avatar_url":null}"#),
        AccessStubResponse(
            #"{"total_count":1,"installations":[{"id":5,"account":{"id":10,"login":"acme","type":"Organization"},"repository_selection":"selected","permissions":{"actions":"read"},"suspended_at":null}]}"#
        ),
        AccessStubResponse(
            #"{\"message\":\"Forbidden\"}"#,
            statusCode: 403,
            headers: [
                "X-GitHub-SSO":
                    "required; url=https://github.com/orgs/acme/sso?authorization_request=sensitive"
            ]
        ),
    ])
    let client = GitHubAccessClient(transport: transport)

    let inventory = try await client.inventory(
        connection: try githubDotComAccessConnection(),
        credential: GitHubCredential(accessToken: "ghu_access")
    )

    #expect(inventory.installations[0].status == .ssoRequired)
    #expect(inventory.installations[0].repositories.isEmpty)
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


@Test
func preservesAndNormalizesRepositoryDefaultBranchMetadata() async throws {
    let transport = AccessQueueTransport([
        AccessStubResponse(
            #"{"total_count":5,"repositories":[{"id":41,"name":"main-repo","full_name":"octocat/main-repo","private":false,"owner":{"id":10,"login":"octocat","type":"User"},"permissions":{"pull":true},"default_branch":" main "},{"id":42,"name":"null-repo","full_name":"octocat/null-repo","private":false,"owner":{"id":10,"login":"octocat","type":"User"},"permissions":{"pull":true},"default_branch":null},{"id":43,"name":"missing-repo","full_name":"octocat/missing-repo","private":false,"owner":{"id":10,"login":"octocat","type":"User"},"permissions":{"pull":true}},{"id":44,"name":"blank-repo","full_name":"octocat/blank-repo","private":false,"owner":{"id":10,"login":"octocat","type":"User"},"permissions":{"pull":true},"default_branch":"  \n  "},{"id":45,"name":"case-repo","full_name":"octocat/case-repo","private":false,"owner":{"id":10,"login":"octocat","type":"User"},"permissions":{"pull":true},"default_branch":"Main"}]}"#
        )
    ])
    let client = GitHubAccessClient(transport: transport)

    let repositories = try await client.repositories(
        installationID: 99,
        connection: try githubDotComAccessConnection(),
        credential: GitHubCredential(accessToken: "ghu_access")
    )

    #expect(repositories.count == 5)
    #expect(repositories[0].defaultBranch == "main")
    #expect(repositories[1].defaultBranch == nil)
    #expect(repositories[2].defaultBranch == nil)
    #expect(repositories[3].defaultBranch == nil)
    #expect(repositories[4].defaultBranch == "Main")
    #expect(await transport.recordedRequests().count == 1)
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

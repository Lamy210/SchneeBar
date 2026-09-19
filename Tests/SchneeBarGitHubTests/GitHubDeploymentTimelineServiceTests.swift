import Foundation
import SchneeBarGitHub
import Testing

private actor DeploymentTimelineCredentialStore: GitHubCredentialStore {
    private var values: [GitHubCredentialKey: GitHubCredential] = [:]
    private var loadCount = 0

    func load(for key: GitHubCredentialKey) async throws -> GitHubCredential? {
        loadCount += 1
        return values[key]
    }

    func save(_ credential: GitHubCredential, for key: GitHubCredentialKey) async throws {
        values[key] = credential
    }

    func delete(for key: GitHubCredentialKey) async throws {
        values.removeValue(forKey: key)
    }

    func recordedLoadCount() -> Int {
        loadCount
    }
}

private actor DeploymentTimelineRoutingTransport: GitHubHTTPTransport {
    private let deploymentListJSON: String
    private let statusesByDeploymentID: [Int64: String]
    private let delayedStatusID: Int64?
    private let delayNanoseconds: UInt64
    private var requests: [URLRequest] = []
    private var delayedStatusStarted = false

    init(
        deploymentListJSON: String,
        statusesByDeploymentID: [Int64: String] = [:],
        delayedStatusID: Int64? = nil,
        delayNanoseconds: UInt64 = 0
    ) {
        self.deploymentListJSON = deploymentListJSON
        self.statusesByDeploymentID = statusesByDeploymentID
        self.delayedStatusID = delayedStatusID
        self.delayNanoseconds = delayNanoseconds
    }

    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        requests.append(request)
        let url = try #require(request.url)
        let path = url.path
        let json: String
        let statusCode: Int

        if path.hasSuffix("/deployments") {
            json = deploymentListJSON
            statusCode = 200
        } else if let deploymentID = statusDeploymentID(from: path),
                  let statusJSON = statusesByDeploymentID[deploymentID]
        {
            if deploymentID == delayedStatusID, delayNanoseconds > 0 {
                delayedStatusStarted = true
                try await Task.sleep(nanoseconds: delayNanoseconds)
            }
            json = statusJSON
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

    func recordedRequests() -> [URLRequest] {
        requests
    }

    func waitUntilDelayedStatusStarts() async {
        while !delayedStatusStarted {
            await Task.yield()
        }
    }

    private func statusDeploymentID(from path: String) -> Int64? {
        let components = path.split(separator: "/").map(String.init)
        guard let deploymentsIndex = components.firstIndex(of: "deployments"),
              components.indices.contains(deploymentsIndex + 2),
              components[deploymentsIndex + 2] == "statuses"
        else {
            return nil
        }
        return Int64(components[deploymentsIndex + 1])
    }
}

@Test
func deploymentTimelineEvidenceAuthorizesOnceAndStopsAfterEmptyList() async throws {
    let transport = DeploymentTimelineRoutingTransport(
        deploymentListJSON: "[]"
    )
    let fixture = try await deploymentTimelineFixture(transport: transport)

    let evidence = try await fixture.service.deploymentEvidence(
        connection: fixture.connection,
        identity: fixture.identity,
        clientID: nil,
        repository: fixture.repository,
        exactSHA: " LANDED-SHA "
    )

    #expect(evidence.exactSHA == "landed-sha")
    #expect(evidence.deployments.isEmpty)
    #expect(await fixture.store.recordedLoadCount() == 1)

    let requests = await transport.recordedRequests()
    #expect(requests.count == 1)
    let request = try #require(requests.first)
    #expect(request.url?.path == "/repos/octocat/project/deployments")
    #expect(queryValue("sha", in: request) == "landed-sha")
    #expect(queryValue("per_page", in: request) == "20")
    #expect(queryValue("page", in: request) == "1")
}

@Test
func deploymentTimelineEvidenceOrdersDeterministicallyAndCapsStatusRequestsAtThree() async throws {
    let transport = DeploymentTimelineRoutingTransport(
        deploymentListJSON: deploymentsJSON([
            deploymentJSON(
                id: 1,
                environment: "staging",
                production: false,
                transient: false,
                createdAt: "2026-09-18T00:00:00Z",
                updatedAt: "2026-09-18T04:00:00Z"
            ),
            deploymentJSON(
                id: 2,
                environment: "production",
                production: true,
                transient: false,
                createdAt: "2026-09-18T00:00:00Z",
                updatedAt: "2026-09-18T04:00:00Z"
            ),
            deploymentJSON(
                id: 3,
                environment: "preview",
                production: true,
                transient: true,
                createdAt: "2026-09-18T00:00:00Z",
                updatedAt: "2026-09-18T03:00:00Z"
            ),
            deploymentJSON(
                id: 4,
                environment: "production-canary",
                production: true,
                transient: false,
                createdAt: "2026-09-18T00:00:00Z",
                updatedAt: "2026-09-18T02:00:00Z"
            ),
        ]),
        statusesByDeploymentID: [
            2: statusListJSON(id: 102, state: "success", environment: "production"),
            4: statusListJSON(id: 104, state: "in_progress", environment: "production-canary"),
            3: statusListJSON(id: 103, state: "pending", environment: "preview"),
            1: statusListJSON(id: 101, state: "success", environment: "staging"),
        ]
    )
    let fixture = try await deploymentTimelineFixture(transport: transport)

    let evidence = try await fixture.service.deploymentEvidence(
        connection: fixture.connection,
        identity: fixture.identity,
        clientID: nil,
        repository: fixture.repository,
        exactSHA: "landed-sha"
    )

    #expect(evidence.deployments.map(\.deployment.id) == [2, 4, 3])
    #expect(evidence.deployments.map(\.latestStatus?.id) == [102, 104, 103])

    let requests = await transport.recordedRequests()
    #expect(requests.count == 4)
    let statusPaths = requests.compactMap { request -> String? in
        guard let path = request.url?.path, path.hasSuffix("/statuses") else {
            return nil
        }
        return path
    }
    #expect(statusPaths == [
        "/repos/octocat/project/deployments/2/statuses",
        "/repos/octocat/project/deployments/4/statuses",
        "/repos/octocat/project/deployments/3/statuses",
    ])
    #expect(requests.dropFirst().allSatisfy { queryValue("per_page", in: $0) == "1" })
    #expect(requests.dropFirst().allSatisfy { queryValue("page", in: $0) == "1" })
}

@Test
func deploymentTimelineEvidenceSortsKnownDatesAheadOfMissingDates() async throws {
    let transport = DeploymentTimelineRoutingTransport(
        deploymentListJSON: deploymentsJSON([
            deploymentJSON(
                id: 10,
                environment: "production-no-date",
                production: true,
                transient: false,
                createdAt: nil,
                updatedAt: nil
            ),
            deploymentJSON(
                id: 11,
                environment: "production-dated",
                production: true,
                transient: false,
                createdAt: "2026-09-18T00:00:00Z",
                updatedAt: "2026-09-18T01:00:00Z"
            ),
        ]),
        statusesByDeploymentID: [
            10: statusListJSON(id: 110, state: "success", environment: "production-no-date"),
            11: statusListJSON(id: 111, state: "success", environment: "production-dated"),
        ]
    )
    let fixture = try await deploymentTimelineFixture(transport: transport)

    let evidence = try await fixture.service.deploymentEvidence(
        connection: fixture.connection,
        identity: fixture.identity,
        clientID: nil,
        repository: fixture.repository,
        exactSHA: "landed-sha"
    )

    #expect(evidence.deployments.map(\.deployment.id) == [11, 10])
}

@Test
func deploymentTimelineEvidenceCancellationStopsLaterStatusRequests() async throws {
    let transport = DeploymentTimelineRoutingTransport(
        deploymentListJSON: deploymentsJSON([
            deploymentJSON(id: 21, environment: "production", production: true, transient: false),
            deploymentJSON(id: 22, environment: "staging", production: false, transient: false),
        ]),
        statusesByDeploymentID: [
            21: statusListJSON(id: 121, state: "success", environment: "production"),
            22: statusListJSON(id: 122, state: "success", environment: "staging"),
        ],
        delayedStatusID: 21,
        delayNanoseconds: 5_000_000_000
    )
    let fixture = try await deploymentTimelineFixture(transport: transport)

    let task = Task {
        try await fixture.service.deploymentEvidence(
            connection: fixture.connection,
            identity: fixture.identity,
            clientID: nil,
            repository: fixture.repository,
            exactSHA: "landed-sha"
        )
    }

    await transport.waitUntilDelayedStatusStarts()
    task.cancel()

    await #expect(throws: CancellationError.self) {
        try await task.value
    }

    let statusRequests = await transport.recordedRequests().filter {
        $0.url?.path.hasSuffix("/statuses") == true
    }
    #expect(statusRequests.count == 1)
    #expect(statusRequests[0].url?.path.contains("/deployments/21/statuses") == true)
}

private struct DeploymentTimelineFixture {
    let service: GitHubDeploymentTimelineService
    let store: DeploymentTimelineCredentialStore
    let connection: GitHubConnection
    let identity: GitHubAccountIdentity
    let repository: GitHubRepositoryAccess
}

private func deploymentTimelineFixture(
    transport: DeploymentTimelineRoutingTransport
) async throws -> DeploymentTimelineFixture {
    let connection = GitHubConnection(
        id: UUID(uuidString: "22222222-3333-4444-5555-666666666666")!,
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
        permissions: GitHubRepositoryPermissions(pull: true)
    )
    let store = DeploymentTimelineCredentialStore()
    try await store.save(
        GitHubCredential(accessToken: "ghu_deployment_timeline"),
        for: GitHubCredentialKey(connectionID: connection.id, accountID: identity.id)
    )
    let coordinator = GitHubConnectionSessionCoordinator(credentialStore: store)
    let service = GitHubDeploymentTimelineService(
        sessionCoordinator: coordinator,
        deploymentClient: GitHubDeploymentClient(transport: transport)
    )
    return DeploymentTimelineFixture(
        service: service,
        store: store,
        connection: connection,
        identity: identity,
        repository: repository
    )
}

private func deploymentsJSON(_ deployments: [String]) -> String {
    "[\(deployments.joined(separator: ","))]"
}

private func deploymentJSON(
    id: Int64,
    environment: String,
    production: Bool,
    transient: Bool,
    createdAt: String? = "2026-09-18T00:00:00Z",
    updatedAt: String? = "2026-09-18T01:00:00Z"
) -> String {
    let created = createdAt.map { "\"\($0)\"" } ?? "null"
    let updated = updatedAt.map { "\"\($0)\"" } ?? "null"
    return """
    {"id":\(id),"sha":"landed-sha","environment":"\(environment)","production_environment":\(production),"transient_environment":\(transient),"created_at":\(created),"updated_at":\(updated)}
    """
}

private func statusListJSON(
    id: Int64,
    state: String,
    environment: String
) -> String {
    """
    [{"id":\(id),"state":"\(state)","environment":"\(environment)","description":null,"environment_url":null,"log_url":null,"created_at":"2026-09-18T00:00:00Z","updated_at":"2026-09-18T01:00:00Z"}]
    """
}

private func queryValue(_ name: String, in request: URLRequest) -> String? {
    guard let url = request.url,
          let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
    else {
        return nil
    }
    return components.queryItems?.first(where: { $0.name == name })?.value
}

import Foundation
import SchneeBarGitHub
import Testing

private actor ServiceCredentialStore: GitHubCredentialStore {
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

private struct ServiceStubResponse: Sendable {
    let json: String
    let statusCode: Int
    let delayNanoseconds: UInt64

    init(
        _ json: String,
        statusCode: Int = 200,
        delayNanoseconds: UInt64 = 0
    ) {
        self.json = json
        self.statusCode = statusCode
        self.delayNanoseconds = delayNanoseconds
    }
}

private actor ServiceQueueTransport: GitHubHTTPTransport {
    private var responses: [ServiceStubResponse]
    private var requests: [URLRequest] = []

    init(_ responses: [ServiceStubResponse]) {
        self.responses = responses
    }

    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        requests.append(request)
        let response = responses.isEmpty
            ? ServiceStubResponse(#"{"message":"Unexpected request"}"#, statusCode: 500)
            : responses.removeFirst()

        if response.delayNanoseconds > 0 {
            try await Task.sleep(nanoseconds: response.delayNanoseconds)
        }

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
func actionsPollingUsesStoredCredentialWithoutRediscoveringAccountOrInventory() async throws {
    let connection = try serviceConnection()
    let identity = GitHubAccountIdentity(id: "100", login: "octocat")
    let key = GitHubCredentialKey(connectionID: connection.id, accountID: identity.id)
    let credentialStore = ServiceCredentialStore()
    try await credentialStore.save(
        GitHubCredential(accessToken: "ghu_service_token"),
        for: key
    )

    let accessTransport = ServiceQueueTransport([])
    let actionsTransport = ServiceQueueTransport([
        ServiceStubResponse(
            #"{"total_count":1,"workflow_runs":[{"id":700,"workflow_id":90,"name":"CI","display_title":"Build","event":"push","status":"in_progress","conclusion":null,"run_number":2,"head_branch":"main","head_sha":"abcdef","pull_requests":[],"created_at":"2026-09-12T10:00:00Z","updated_at":"2026-09-12T10:01:00Z"}]}"#
        )
    ])

    let sessionCoordinator = GitHubConnectionSessionCoordinator(
        credentialStore: credentialStore,
        accessClient: GitHubAccessClient(transport: accessTransport)
    )
    let service = GitHubWorkflowRunService(
        sessionCoordinator: sessionCoordinator,
        actionsClient: GitHubActionsClient(transport: actionsTransport)
    )

    let runs = try await service.workflowRuns(
        connection: connection,
        identity: identity,
        clientID: nil,
        repository: try serviceRepository()
    )

    #expect(runs.map(\.id) == [700])
    #expect(runs[0].status == .inProgress)
    #expect(await accessTransport.recordedRequests().isEmpty)

    let actionsRequest = try #require(await actionsTransport.recordedRequests().first)
    #expect(actionsRequest.url?.path == "/repos/octocat/project/actions/runs")
    #expect(
        actionsRequest.value(forHTTPHeaderField: "Authorization")
            == "Bearer ghu_service_token"
    )
}

@Test
func missingCredentialFailsBeforeActionsRequest() async throws {
    let connection = try serviceConnection()
    let identity = GitHubAccountIdentity(id: "100", login: "octocat")
    let credentialStore = ServiceCredentialStore()
    let actionsTransport = ServiceQueueTransport([])

    let service = GitHubWorkflowRunService(
        sessionCoordinator: GitHubConnectionSessionCoordinator(
            credentialStore: credentialStore
        ),
        actionsClient: GitHubActionsClient(transport: actionsTransport)
    )

    await #expect(throws: GitHubConnectionSessionError.credentialNotFound) {
        try await service.workflowRuns(
            connection: connection,
            identity: identity,
            clientID: nil,
            repository: try serviceRepository()
        )
    }

    #expect(await actionsTransport.recordedRequests().isEmpty)
}

@Test
func actionsPollingRefreshesExpiringCredentialWithoutInventoryDiscovery() async throws {
    let now = Date(timeIntervalSince1970: 1_789_200_000)
    let connection = try serviceConnection()
    let identity = GitHubAccountIdentity(id: "100", login: "octocat")
    let key = GitHubCredentialKey(connectionID: connection.id, accountID: identity.id)
    let credentialStore = ServiceCredentialStore()
    try await credentialStore.save(
        GitHubCredential(
            accessToken: "old_access",
            refreshToken: "old_refresh",
            accessTokenExpiresAt: now.addingTimeInterval(30),
            refreshTokenExpiresAt: now.addingTimeInterval(3_600)
        ),
        for: key
    )

    let accessTransport = ServiceQueueTransport([])
    let refreshTransport = ServiceQueueTransport([
        ServiceStubResponse(
            #"{"access_token":"new_access","refresh_token":"new_refresh","expires_in":28800,"refresh_token_expires_in":15811200,"token_type":"bearer","scope":""}"#
        )
    ])
    let actionsTransport = ServiceQueueTransport([
        ServiceStubResponse(#"{"total_count":0,"workflow_runs":[]}"#)
    ])

    let coordinator = GitHubConnectionSessionCoordinator(
        credentialStore: credentialStore,
        accessClient: GitHubAccessClient(transport: accessTransport),
        deviceFlowClient: GitHubDeviceFlowClient(
            transport: refreshTransport,
            now: { now }
        ),
        now: { now }
    )
    let service = GitHubWorkflowRunService(
        sessionCoordinator: coordinator,
        actionsClient: GitHubActionsClient(transport: actionsTransport)
    )

    _ = try await service.workflowRuns(
        connection: connection,
        identity: identity,
        clientID: "Iv1.public-client-id",
        repository: try serviceRepository()
    )

    #expect(await accessTransport.recordedRequests().isEmpty)
    #expect(await refreshTransport.recordedRequests().count == 1)

    let actionsRequest = try #require(await actionsTransport.recordedRequests().first)
    #expect(
        actionsRequest.value(forHTTPHeaderField: "Authorization")
            == "Bearer new_access"
    )

    let persisted = try #require(try await credentialStore.load(for: key))
    #expect(persisted.accessToken == "new_access")
    #expect(persisted.refreshToken == "new_refresh")
}

@Test
func concurrentActionsPollingSharesOneRefreshRotation() async throws {
    let now = Date(timeIntervalSince1970: 1_789_200_000)
    let connection = try serviceConnection()
    let identity = GitHubAccountIdentity(id: "100", login: "octocat")
    let key = GitHubCredentialKey(connectionID: connection.id, accountID: identity.id)
    let credentialStore = ServiceCredentialStore()
    try await credentialStore.save(
        GitHubCredential(
            accessToken: "old_access",
            refreshToken: "old_refresh",
            accessTokenExpiresAt: now.addingTimeInterval(30),
            refreshTokenExpiresAt: now.addingTimeInterval(3_600)
        ),
        for: key
    )

    let refreshTransport = ServiceQueueTransport([
        ServiceStubResponse(
            #"{"access_token":"new_access","refresh_token":"new_refresh","expires_in":28800,"refresh_token_expires_in":15811200,"token_type":"bearer","scope":""}"#,
            delayNanoseconds: 100_000_000
        )
    ])
    let actionsTransport = ServiceQueueTransport([
        ServiceStubResponse(#"{"total_count":0,"workflow_runs":[]}"#),
        ServiceStubResponse(#"{"total_count":0,"workflow_runs":[]}"#),
    ])

    let coordinator = GitHubConnectionSessionCoordinator(
        credentialStore: credentialStore,
        deviceFlowClient: GitHubDeviceFlowClient(
            transport: refreshTransport,
            now: { now }
        ),
        now: { now }
    )
    let service = GitHubWorkflowRunService(
        sessionCoordinator: coordinator,
        actionsClient: GitHubActionsClient(transport: actionsTransport)
    )
    let repository = try serviceRepository()

    async let first = service.workflowRuns(
        connection: connection,
        identity: identity,
        clientID: "Iv1.public-client-id",
        repository: repository
    )
    async let second = service.workflowRuns(
        connection: connection,
        identity: identity,
        clientID: "Iv1.public-client-id",
        repository: repository
    )

    _ = try await (first, second)

    #expect(await refreshTransport.recordedRequests().count == 1)
    let actionRequests = await actionsTransport.recordedRequests()
    #expect(actionRequests.count == 2)
    #expect(
        actionRequests.allSatisfy {
            $0.value(forHTTPHeaderField: "Authorization") == "Bearer new_access"
        }
    )
}

private func serviceConnection() throws -> GitHubConnection {
    GitHubConnection(
        id: UUID(uuidString: "30000000-0000-0000-0000-000000000001")!,
        displayName: "GitHub.com",
        deploymentKind: .githubDotCom,
        webBaseURL: try #require(URL(string: "https://github.com"))
    )
}

private func serviceRepository() throws -> GitHubRepositoryAccess {
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

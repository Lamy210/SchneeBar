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

    init(_ json: String, statusCode: Int = 200) {
        self.json = json
        self.statusCode = statusCode
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
func restoresSessionThenLoadsActionsWithoutExposingCredentialInResult() async throws {
    let connection = try serviceConnection()
    let identity = GitHubAccountIdentity(id: "100", login: "octocat")
    let key = GitHubCredentialKey(connectionID: connection.id, accountID: identity.id)
    let credentialStore = ServiceCredentialStore()
    try await credentialStore.save(
        GitHubCredential(accessToken: "ghu_service_token"),
        for: key
    )

    let accessTransport = ServiceQueueTransport([
        ServiceStubResponse(
            #"{"id":100,"login":"octocat","name":"Octo Cat","avatar_url":null}"#
        ),
        ServiceStubResponse(#"{"total_count":0,"installations":[]}"#),
    ])
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
        credentialStore: credentialStore,
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

    let accessRequests = await accessTransport.recordedRequests()
    #expect(accessRequests.count == 2)
    #expect(accessRequests[0].url?.path == "/user")
    #expect(accessRequests[1].url?.path == "/user/installations")

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
    let accessTransport = ServiceQueueTransport([])
    let actionsTransport = ServiceQueueTransport([])

    let service = GitHubWorkflowRunService(
        credentialStore: credentialStore,
        sessionCoordinator: GitHubConnectionSessionCoordinator(
            credentialStore: credentialStore,
            accessClient: GitHubAccessClient(transport: accessTransport)
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

    #expect(await accessTransport.recordedRequests().isEmpty)
    #expect(await actionsTransport.recordedRequests().isEmpty)
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

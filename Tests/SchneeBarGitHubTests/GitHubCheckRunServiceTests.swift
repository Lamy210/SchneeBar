import Foundation
import SchneeBarGitHub
import Testing

private actor CheckServiceCredentialStore: GitHubCredentialStore {
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

private actor CheckServiceTransport: GitHubHTTPTransport {
    private let json: String
    private var requests: [URLRequest] = []

    init(json: String) {
        self.json = json
    }

    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        requests.append(request)
        let response = try #require(
            HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
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
func checkPollingUsesStoredCredential() async throws {
    let connection = try checkServiceConnection()
    let identity = GitHubAccountIdentity(id: "100", login: "octocat")
    let key = GitHubCredentialKey(connectionID: connection.id, accountID: identity.id)
    let credentialStore = CheckServiceCredentialStore()
    try await credentialStore.save(
        GitHubCredential(accessToken: "ghu_check_token"),
        for: key
    )
    let sha = String(repeating: "a", count: 40)
    let transport = CheckServiceTransport(
        json: "{\"check_runs\":[{\"id\":7,\"name\":\"Codecov\",\"status\":\"completed\",\"conclusion\":\"failure\",\"head_sha\":\"\(sha)\",\"started_at\":\"2026-09-16T00:00:00Z\",\"completed_at\":\"2026-09-16T00:01:00Z\",\"app\":{\"slug\":\"codecov\"}}]}"
    )
    let service = GitHubCheckRunService(
        sessionCoordinator: GitHubConnectionSessionCoordinator(
            credentialStore: credentialStore
        ),
        client: GitHubCheckRunClient(transport: transport)
    )

    let runs = try await service.checkRuns(
        connection: connection,
        identity: identity,
        clientID: nil,
        repository: try checkServiceRepository(),
        headSHA: sha
    )

    #expect(runs.map(\.id) == [7])
    let request = try #require(await transport.recordedRequests().first)
    #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer ghu_check_token")
}

@Test
func missingCredentialFailsBeforeCheckRequest() async throws {
    let connection = try checkServiceConnection()
    let identity = GitHubAccountIdentity(id: "100", login: "octocat")
    let transport = CheckServiceTransport(json: #"{"check_runs":[]}"#)
    let service = GitHubCheckRunService(
        sessionCoordinator: GitHubConnectionSessionCoordinator(
            credentialStore: CheckServiceCredentialStore()
        ),
        client: GitHubCheckRunClient(transport: transport)
    )

    await #expect(throws: GitHubConnectionSessionError.credentialNotFound) {
        try await service.checkRuns(
            connection: connection,
            identity: identity,
            clientID: nil,
            repository: try checkServiceRepository(),
            headSHA: String(repeating: "a", count: 40)
        )
    }
    #expect(await transport.recordedRequests().isEmpty)
}

private func checkServiceConnection() throws -> GitHubConnection {
    GitHubConnection(
        id: UUID(uuidString: "50000000-0000-0000-0000-000000000001")!,
        displayName: "GitHub.com",
        deploymentKind: .githubDotCom,
        webBaseURL: try #require(URL(string: "https://github.com"))
    )
}

private func checkServiceRepository() throws -> GitHubRepositoryAccess {
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

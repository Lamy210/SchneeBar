import Foundation
import SchneeBarGitHub
import Testing

private actor MutationServiceCredentialStore: GitHubCredentialStore {
    private var values: [GitHubCredentialKey: GitHubCredential] = [:]

    func load(for key: GitHubCredentialKey) async throws -> GitHubCredential? {
        values[key]
    }

    func save(
        _ credential: GitHubCredential,
        for key: GitHubCredentialKey
    ) async throws {
        values[key] = credential
    }

    func delete(for key: GitHubCredentialKey) async throws {
        values.removeValue(forKey: key)
    }
}

private actor MutationServiceTransport: GitHubHTTPTransport {
    private let statusCode: Int
    private var requests: [URLRequest] = []

    init(statusCode: Int) {
        self.statusCode = statusCode
    }

    func data(
        for request: URLRequest
    ) async throws -> (Data, HTTPURLResponse) {
        requests.append(request)
        let response = try #require(
            HTTPURLResponse(
                url: request.url!,
                statusCode: statusCode,
                httpVersion: "HTTP/1.1",
                headerFields: nil
            )
        )
        return (Data(), response)
    }

    func recordedRequests() -> [URLRequest] {
        requests
    }
}

@Test
func mutationServiceUsesStoredCredentialWithoutRediscovery() async throws {
    let connection = try mutationServiceConnection()
    let identity = GitHubAccountIdentity(id: "100", login: "octocat")
    let store = MutationServiceCredentialStore()
    try await store.save(
        GitHubCredential(accessToken: "ghu_write"),
        for: GitHubCredentialKey(
            connectionID: connection.id,
            accountID: identity.id
        )
    )
    let transport = MutationServiceTransport(statusCode: 201)
    let service = GitHubWorkflowRunMutationService(
        sessionCoordinator: GitHubConnectionSessionCoordinator(
            credentialStore: store
        ),
        client: GitHubWorkflowRunMutationClient(transport: transport)
    )

    try await service.rerun(
        connection: connection,
        identity: identity,
        clientID: nil,
        repository: try mutationServiceRepository(),
        runID: 42
    )

    let request = try #require(await transport.recordedRequests().last)
    #expect(request.httpMethod == "POST")
    #expect(request.url?.path == "/repos/octocat/project/actions/runs/42/rerun")
    #expect(
        request.value(forHTTPHeaderField: "Authorization")
            == "Bearer ghu_write"
    )
}

@Test
func mutationServiceMissingCredentialStopsBeforeMutationRequest() async throws {
    let connection = try mutationServiceConnection()
    let identity = GitHubAccountIdentity(id: "100", login: "octocat")
    let transport = MutationServiceTransport(statusCode: 201)
    let service = GitHubWorkflowRunMutationService(
        sessionCoordinator: GitHubConnectionSessionCoordinator(
            credentialStore: MutationServiceCredentialStore()
        ),
        client: GitHubWorkflowRunMutationClient(transport: transport)
    )

    await #expect(throws: GitHubConnectionSessionError.credentialNotFound) {
        try await service.rerun(
            connection: connection,
            identity: identity,
            clientID: nil,
            repository: try mutationServiceRepository(),
            runID: 42
        )
    }

    #expect(await transport.recordedRequests().isEmpty)
}

private func mutationServiceConnection() throws -> GitHubConnection {
    GitHubConnection(
        id: UUID(uuidString: "31000000-0000-0000-0000-000000000001")!,
        displayName: "GitHub.com",
        deploymentKind: .githubDotCom,
        webBaseURL: try #require(URL(string: "https://github.com"))
    )
}

private func mutationServiceRepository() throws -> GitHubRepositoryAccess {
    GitHubRepositoryAccess(
        id: 42,
        name: "project",
        fullName: "octocat/project",
        isPrivate: true,
        webURL: try #require(
            URL(string: "https://github.com/octocat/project")
        ),
        ownerLogin: "octocat",
        permissions: GitHubRepositoryPermissions(
            push: true,
            pull: true
        )
    )
}

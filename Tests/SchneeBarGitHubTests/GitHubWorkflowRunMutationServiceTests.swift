import Foundation
import SchneeBarGitHub
import Testing

private actor MutationServiceCredentialStore: GitHubCredentialStore {
    private let key: GitHubCredentialKey
    private var credential: GitHubCredential?

    init(
        connection: GitHubConnection,
        identity: GitHubAccountIdentity,
        credential: GitHubCredential?
    ) {
        key = GitHubCredentialKey(
            connectionID: connection.id,
            accountID: identity.id
        )
        self.credential = credential
    }

    func load(for key: GitHubCredentialKey) async throws -> GitHubCredential? {
        key == self.key ? credential : nil
    }

    func save(
        _ credential: GitHubCredential,
        for key: GitHubCredentialKey
    ) async throws {
        if key == self.key {
            self.credential = credential
        }
    }

    func delete(for key: GitHubCredentialKey) async throws {
        if key == self.key {
            credential = nil
        }
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
func workflowMutationServiceUsesStoredCredentialWithoutInventoryDiscovery() async throws {
    let connection = try mutationServiceConnection()
    let identity = GitHubAccountIdentity(id: "42", login: "octocat")
    let store = MutationServiceCredentialStore(
        connection: connection,
        identity: identity,
        credential: GitHubCredential(accessToken: "ghu_write")
    )
    let transport = MutationServiceTransport(statusCode: 201)
    let service = GitHubWorkflowRunMutationService(
        sessionCoordinator: GitHubConnectionSessionCoordinator(
            credentialStore: store
        ),
        mutationClient: GitHubWorkflowRunMutationClient(
            transport: transport
        )
    )

    try await service.rerun(
        connection: connection,
        identity: identity,
        clientID: nil,
        repository: try mutationServiceRepository(),
        runID: 700
    )

    let requests = await transport.recordedRequests()
    #expect(requests.count == 1)
    #expect(requests[0].httpMethod == "POST")
    #expect(
        requests[0].value(forHTTPHeaderField: "Authorization")
            == "Bearer ghu_write"
    )
}

@Test
func workflowMutationServiceStopsBeforeNetworkWhenCredentialIsMissing() async throws {
    let connection = try mutationServiceConnection()
    let identity = GitHubAccountIdentity(id: "42", login: "octocat")
    let store = MutationServiceCredentialStore(
        connection: connection,
        identity: identity,
        credential: nil
    )
    let transport = MutationServiceTransport(statusCode: 201)
    let service = GitHubWorkflowRunMutationService(
        sessionCoordinator: GitHubConnectionSessionCoordinator(
            credentialStore: store
        ),
        mutationClient: GitHubWorkflowRunMutationClient(
            transport: transport
        )
    )

    await #expect(
        throws: GitHubConnectionSessionError.credentialNotFound
    ) {
        try await service.rerun(
            connection: connection,
            identity: identity,
            clientID: nil,
            repository: try mutationServiceRepository(),
            runID: 700
        )
    }

    #expect(await transport.recordedRequests().isEmpty)
}

private func mutationServiceConnection() throws -> GitHubConnection {
    GitHubConnection(
        id: UUID(uuidString: "84000000-0000-0000-0000-000000000001")!,
        displayName: "GitHub.com",
        deploymentKind: .githubDotCom,
        webBaseURL: try #require(URL(string: "https://github.com"))
    )
}

private func mutationServiceRepository() throws -> GitHubRepositoryAccess {
    GitHubRepositoryAccess(
        id: 1,
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

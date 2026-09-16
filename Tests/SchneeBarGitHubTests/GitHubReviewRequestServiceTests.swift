import Foundation
import SchneeBarGitHub
import Testing

private actor ReviewServiceCredentialStore: GitHubCredentialStore {
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

private actor ReviewServiceTransport: GitHubHTTPTransport {
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
func reviewPollingUsesStoredCredentialWithoutInventoryDiscovery() async throws {
    let connection = try reviewServiceConnection()
    let identity = GitHubAccountIdentity(id: "100", login: "octocat")
    let key = GitHubCredentialKey(connectionID: connection.id, accountID: identity.id)
    let credentialStore = ReviewServiceCredentialStore()
    try await credentialStore.save(
        GitHubCredential(accessToken: "ghu_review_token"),
        for: key
    )
    let transport = ReviewServiceTransport(
        json: #"[{"number":7,"title":"Review me","draft":false,"updated_at":"2026-09-16T00:00:00Z","head":{"sha":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"},"requested_reviewers":[{"id":100}]}]"#
    )
    let service = GitHubReviewRequestService(
        sessionCoordinator: GitHubConnectionSessionCoordinator(
            credentialStore: credentialStore
        ),
        client: GitHubPullRequestListClient(transport: transport)
    )

    let requests = try await service.reviewRequests(
        connection: connection,
        identity: identity,
        clientID: nil,
        repository: try reviewServiceRepository()
    )

    #expect(requests.map(\.number) == [7])
    let request = try #require(await transport.recordedRequests().first)
    #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer ghu_review_token")
}

@Test
func missingCredentialFailsBeforeReviewRequest() async throws {
    let connection = try reviewServiceConnection()
    let identity = GitHubAccountIdentity(id: "100", login: "octocat")
    let transport = ReviewServiceTransport(json: "[]")
    let service = GitHubReviewRequestService(
        sessionCoordinator: GitHubConnectionSessionCoordinator(
            credentialStore: ReviewServiceCredentialStore()
        ),
        client: GitHubPullRequestListClient(transport: transport)
    )

    await #expect(throws: GitHubConnectionSessionError.credentialNotFound) {
        try await service.reviewRequests(
            connection: connection,
            identity: identity,
            clientID: nil,
            repository: try reviewServiceRepository()
        )
    }
    #expect(await transport.recordedRequests().isEmpty)
}

private func reviewServiceConnection() throws -> GitHubConnection {
    GitHubConnection(
        id: UUID(uuidString: "40000000-0000-0000-0000-000000000001")!,
        displayName: "GitHub.com",
        deploymentKind: .githubDotCom,
        webBaseURL: try #require(URL(string: "https://github.com"))
    )
}

private func reviewServiceRepository() throws -> GitHubRepositoryAccess {
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

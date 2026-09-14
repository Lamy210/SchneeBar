import Foundation
import SchneeBarGitHub
import Testing

private actor MetadataServiceCredentialStore: GitHubCredentialStore {
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

private actor MetadataServiceTransport: GitHubHTTPTransport {
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
func pullRequestMetadataServiceUsesAuthorizedStoredCredential() async throws {
    let connection = try metadataServiceConnection()
    let identity = GitHubAccountIdentity(id: "100", login: "octocat")
    let store = MetadataServiceCredentialStore()
    try await store.save(
        GitHubCredential(accessToken: "ghu_metadata_service"),
        for: GitHubCredentialKey(connectionID: connection.id, accountID: identity.id)
    )

    let transport = MetadataServiceTransport(
        json: #"{"number":25,"state":"closed","draft":false,"merged":true,"merge_commit_sha":"landed","head":{"ref":"feature/jobs","sha":"head-final"},"base":{"ref":"main","sha":"base-before"},"updated_at":"2026-09-12T12:02:00Z","merged_at":"2026-09-12T12:01:00Z"}"#
    )
    let service = GitHubPullRequestMetadataService(
        sessionCoordinator: GitHubConnectionSessionCoordinator(
            credentialStore: store
        ),
        metadataClient: GitHubPullRequestMetadataClient(transport: transport)
    )

    let metadata = try await service.pullRequest(
        number: 25,
        connection: connection,
        identity: identity,
        clientID: nil,
        repository: try metadataServiceRepository()
    )

    #expect(metadata.number == 25)
    #expect(metadata.isMerged)
    #expect(metadata.mergeCommitSHA == "landed")

    let request = try #require(await transport.recordedRequests().first)
    #expect(request.url?.path == "/repos/octocat/project/pulls/25")
    #expect(
        request.value(forHTTPHeaderField: "Authorization")
            == "Bearer ghu_metadata_service"
    )
}

@Test
func pullRequestMetadataServiceFailsBeforeRequestWhenCredentialIsMissing() async throws {
    let connection = try metadataServiceConnection()
    let identity = GitHubAccountIdentity(id: "100", login: "octocat")
    let transport = MetadataServiceTransport(json: #"{}"#)
    let service = GitHubPullRequestMetadataService(
        sessionCoordinator: GitHubConnectionSessionCoordinator(
            credentialStore: MetadataServiceCredentialStore()
        ),
        metadataClient: GitHubPullRequestMetadataClient(transport: transport)
    )

    await #expect(throws: GitHubConnectionSessionError.credentialNotFound) {
        _ = try await service.pullRequest(
            number: 25,
            connection: connection,
            identity: identity,
            clientID: nil,
            repository: try metadataServiceRepository()
        )
    }

    #expect(await transport.recordedRequests().isEmpty)
}

private func metadataServiceConnection() throws -> GitHubConnection {
    GitHubConnection(
        displayName: "GitHub.com",
        deploymentKind: .githubDotCom,
        webBaseURL: try #require(URL(string: "https://github.com"))
    )
}

private func metadataServiceRepository() throws -> GitHubRepositoryAccess {
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

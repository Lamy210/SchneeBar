@testable import SchneeBar
import Foundation
import SchneeBarGitHub
import SchneeBarGitHubActivityProvider
import Testing

private actor ProfileCollisionStore: GitHubConnectionProfileStore {
    private let profiles: [GitHubConnectionProfile]

    init(_ profiles: [GitHubConnectionProfile]) {
        self.profiles = profiles
    }

    func loadAll() async throws -> [GitHubConnectionProfile] {
        profiles
    }

    func load(id: UUID) async throws -> GitHubConnectionProfile? {
        profiles.first(where: { $0.id == id })
    }

    func save(_ profile: GitHubConnectionProfile) async throws {}

    func delete(id: UUID) async throws {}
}

private actor ProfileCollisionCredentialStore: GitHubCredentialStore {
    func load(
        for key: GitHubCredentialKey
    ) async throws -> GitHubCredential? {
        nil
    }

    func save(
        _ credential: GitHubCredential,
        for key: GitHubCredentialKey
    ) async throws {}

    func delete(for key: GitHubCredentialKey) async throws {}
}

private actor ProfileCollisionTransport: GitHubHTTPTransport {
    private var count = 0

    func data(
        for request: URLRequest
    ) async throws -> (Data, HTTPURLResponse) {
        count += 1
        let response = try #require(
            HTTPURLResponse(
                url: request.url!,
                statusCode: 500,
                httpVersion: "HTTP/1.1",
                headerFields: nil
            )
        )
        return (
            Data(#"{"message":"unexpected request"}"#.utf8),
            response
        )
    }

    func requestCount() -> Int {
        count
    }
}

private struct ProfileCollisionWorkflowLoader: GitHubWorkflowRunLoading {
    func workflowRuns(
        connection: GitHubConnection,
        identity: GitHubAccountIdentity,
        clientID: String?,
        repository: GitHubRepositoryAccess,
        query: GitHubWorkflowRunQuery
    ) async throws -> [GitHubWorkflowRun] {
        []
    }
}

@Test @MainActor
func loadQuarantinesAmbiguousProfileIdentityWithoutRefreshing() async throws {
    let first = try profileCollisionProfile(
        id: UUID(
            uuidString: "77000000-0000-0000-0000-000000000001"
        )!,
        webURL: "https://github.com",
        login: "old-login"
    )
    let second = try profileCollisionProfile(
        id: UUID(
            uuidString: "77000000-0000-0000-0000-000000000002"
        )!,
        webURL: "https://GITHUB.COM/",
        login: "renamed-login"
    )
    let profileStore = ProfileCollisionStore([first, second])
    let credentialStore = ProfileCollisionCredentialStore()
    let transport = ProfileCollisionTransport()
    let coordinator = GitHubConnectionSessionCoordinator(
        credentialStore: credentialStore,
        accessClient: GitHubAccessClient(transport: transport)
    )
    let model = GitHubConnectionsRuntimeModel(
        profileStore: profileStore,
        sessionCoordinator: coordinator,
        activityProvider: GitHubActivityProvider(
            workflowRunLoader: ProfileCollisionWorkflowLoader()
        )
    )

    await model.load()

    #expect(Set(model.profiles.map(\.id)) == Set([first.id, second.id]))
    #expect(model.statusByConnectionID[first.id] == .unavailable)
    #expect(model.statusByConnectionID[second.id] == .unavailable)
    #expect(await transport.requestCount() == 0)
}

private func profileCollisionProfile(
    id: UUID,
    webURL: String,
    login: String
) throws -> GitHubConnectionProfile {
    GitHubConnectionProfile(
        connection: GitHubConnection(
            id: id,
            displayName: "GitHub.com",
            deploymentKind: .githubDotCom,
            webBaseURL: try #require(URL(string: webURL))
        ),
        account: GitHubAccountIdentity(
            id: "42",
            login: login
        ),
        authenticationMethod: .deviceFlow,
        clientID: "test-client-id"
    )
}

@testable import SchneeBar
import Foundation
import SchneeBarGitHub
import SchneeBarGitHubActivityProvider
import SchneeBarGitHubFeature
import Testing

private actor EnterpriseStatusProfileStore: GitHubConnectionProfileStore {
    private var profile: GitHubConnectionProfile

    init(profile: GitHubConnectionProfile) {
        self.profile = profile
    }

    func loadAll() async throws -> [GitHubConnectionProfile] { [profile] }

    func load(id: UUID) async throws -> GitHubConnectionProfile? {
        profile.id == id ? profile : nil
    }

    func save(_ profile: GitHubConnectionProfile) async throws {
        self.profile = profile
    }

    func delete(id: UUID) async throws {}
}

private actor EnterpriseStatusCredentialStore: GitHubCredentialStore {
    private let key: GitHubCredentialKey
    private var credential: GitHubCredential?

    init(profile: GitHubConnectionProfile) {
        key = GitHubCredentialKey(
            connectionID: profile.id,
            accountID: profile.account.id
        )
        credential = GitHubCredential(accessToken: "enterprise-status-token")
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

private actor EnterpriseStatusTransport: GitHubHTTPTransport {
    private var responses: [String]

    init(responses: [String]) {
        self.responses = responses
    }

    func data(
        for request: URLRequest
    ) async throws -> (Data, HTTPURLResponse) {
        let json = responses.removeFirst()
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
}

private struct EnterpriseStatusWorkflowLoader: GitHubWorkflowRunLoading {
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
func refreshSurfacesUntestedEnterpriseServerVersion() async throws {
    let profile = try enterpriseStatusProfile(serverVersion: "3.19.9")
    let model = enterpriseStatusModel(profile: profile)
    model.profiles = [profile]

    await model.refresh(profileID: profile.id)

    let card = try #require(model.connectionCards.first)
    #expect(card.status == .untestedServer(version: "3.19.9"))
}

@Test @MainActor
func refreshKeepsTestedEnterpriseServerVersionConnected() async throws {
    let profile = try enterpriseStatusProfile(serverVersion: "3.22.0")
    let model = enterpriseStatusModel(profile: profile)
    model.profiles = [profile]

    await model.refresh(profileID: profile.id)

    let card = try #require(model.connectionCards.first)
    #expect(card.status == .connected(repositoryCount: 1))
}

@MainActor
private func enterpriseStatusModel(
    profile: GitHubConnectionProfile
) -> GitHubConnectionsRuntimeModel {
    let credentialStore = EnterpriseStatusCredentialStore(profile: profile)
    let transport = EnterpriseStatusTransport(
        responses: enterpriseStatusResponses()
    )
    let coordinator = GitHubConnectionSessionCoordinator(
        credentialStore: credentialStore,
        accessClient: GitHubAccessClient(transport: transport)
    )

    return GitHubConnectionsRuntimeModel(
        profileStore: EnterpriseStatusProfileStore(profile: profile),
        sessionCoordinator: coordinator,
        activityProvider: GitHubActivityProvider(
            workflowRunLoader: EnterpriseStatusWorkflowLoader()
        )
    )
}

private func enterpriseStatusProfile(
    serverVersion: String
) throws -> GitHubConnectionProfile {
    GitHubConnectionProfile(
        connection: GitHubConnection(
            id: UUID(uuidString: "67000000-0000-0000-0000-000000000001")!,
            displayName: "Internal GitHub",
            deploymentKind: .enterpriseServer,
            webBaseURL: try #require(
                URL(string: "https://github.internal.example")
            ),
            serverVersion: serverVersion
        ),
        account: GitHubAccountIdentity(
            id: "42",
            login: "snow-user"
        ),
        authenticationMethod: .deviceFlow,
        clientID: "test-client-id",
        repositorySelection: .allAccessible,
        isEnabled: true
    )
}

private func enterpriseStatusResponses() -> [String] {
    [
        #"{"id":42,"login":"snow-user","name":"Snow User","avatar_url":null}"#,
        #"{"id":42,"login":"snow-user","name":"Snow User","avatar_url":null}"#,
        #"{"total_count":1,"installations":[{"id":10,"account":{"id":100,"login":"snow","type":"Organization","avatar_url":null},"repository_selection":"all","permissions":{"actions":"read"},"suspended_at":null}]}"#,
        #"{"total_count":1,"repositories":[{"id":1,"name":"app","full_name":"snow/app","private":true,"owner":{"id":100,"login":"snow","type":"Organization","avatar_url":null},"permissions":{"admin":false,"maintain":false,"push":false,"triage":false,"pull":true}}]}"#,
    ]
}

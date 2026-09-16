@testable import SchneeBar
import Foundation
import SchneeBarGitHub
import SchneeBarGitHubActivityProvider
import SchneeBarGitHubFeature
import Testing

private actor CapabilityPresentationProfileStore: GitHubConnectionProfileStore {
    private var profile: GitHubConnectionProfile

    init(profile: GitHubConnectionProfile) {
        self.profile = profile
    }

    func loadAll() async throws -> [GitHubConnectionProfile] { [profile] }
    func load(id: UUID) async throws -> GitHubConnectionProfile? { profile.id == id ? profile : nil }
    func save(_ profile: GitHubConnectionProfile) async throws { self.profile = profile }
    func delete(id: UUID) async throws {}
}

private actor CapabilityPresentationCredentialStore: GitHubCredentialStore {
    private let key: GitHubCredentialKey
    private var credential: GitHubCredential?

    init(profile: GitHubConnectionProfile) {
        key = GitHubCredentialKey(connectionID: profile.id, accountID: profile.account.id)
        credential = GitHubCredential(accessToken: "presentation-token")
    }

    func load(for key: GitHubCredentialKey) async throws -> GitHubCredential? {
        key == self.key ? credential : nil
    }

    func save(_ credential: GitHubCredential, for key: GitHubCredentialKey) async throws {
        if key == self.key { self.credential = credential }
    }

    func delete(for key: GitHubCredentialKey) async throws {
        if key == self.key { credential = nil }
    }
}

private struct CapabilityPresentationResponse: Sendable {
    let json: String
}

private actor CapabilityPresentationTransport: GitHubHTTPTransport {
    private var responses: [CapabilityPresentationResponse]

    init(_ responses: [CapabilityPresentationResponse]) {
        self.responses = responses
    }

    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let response = responses.removeFirst()
        let httpResponse = try #require(
            HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: "HTTP/1.1",
                headerFields: nil
            )
        )
        return (Data(response.json.utf8), httpResponse)
    }
}

private struct CapabilityPresentationWorkflowLoader: GitHubWorkflowRunLoading {
    func workflowRuns(
        connection: GitHubConnection,
        identity: GitHubAccountIdentity,
        clientID: String?,
        repository: GitHubRepositoryAccess,
        query: GitHubWorkflowRunQuery
    ) async throws -> [GitHubWorkflowRun] { [] }
}

private struct CapabilityPresentationReviewLoader: GitHubReviewRequestLoading {
    func reviewRequests(
        connection: GitHubConnection,
        identity: GitHubAccountIdentity,
        clientID: String?,
        repository: GitHubRepositoryAccess
    ) async throws -> [GitHubReviewRequest] { [] }
}

private struct CapabilityPresentationCheckLoader: GitHubCheckRunLoading {
    func checkRuns(
        connection: GitHubConnection,
        identity: GitHubAccountIdentity,
        clientID: String?,
        repository: GitHubRepositoryAccess,
        headSHA: String
    ) async throws -> [GitHubCheckRun] { [] }
}

@Test @MainActor
func managementModelMapsActionsReviewsAndChecksIndependently() async throws {
    let profile = try capabilityPresentationProfile()
    let profileStore = CapabilityPresentationProfileStore(profile: profile)
    let credentialStore = CapabilityPresentationCredentialStore(profile: profile)
    let transport = CapabilityPresentationTransport(capabilityPresentationResponses())
    let coordinator = GitHubConnectionSessionCoordinator(
        credentialStore: credentialStore,
        accessClient: GitHubAccessClient(transport: transport)
    )
    let provider = GitHubActivityProvider(
        workflowRunLoader: CapabilityPresentationWorkflowLoader(),
        reviewRequestLoader: CapabilityPresentationReviewLoader(),
        checkRunLoader: CapabilityPresentationCheckLoader()
    )
    let model = GitHubConnectionsRuntimeModel(
        profileStore: profileStore,
        sessionCoordinator: coordinator,
        activityProvider: provider
    )
    model.profiles = [profile]

    await model.refresh(profileID: profile.id)

    let management = try #require(model.managementModel(profileID: profile.id))
    let repository = try #require(management.repositories.first)
    #expect(repository.activityAccess.actions == .available)
    #expect(repository.activityAccess.reviewRequests == .unavailable)
    #expect(repository.activityAccess.checks == .unverified)
}

private func capabilityPresentationProfile() throws -> GitHubConnectionProfile {
    GitHubConnectionProfile(
        connection: GitHubConnection(
            id: UUID(uuidString: "65000000-0000-0000-0000-000000000001")!,
            displayName: "GitHub.com",
            deploymentKind: .githubDotCom,
            webBaseURL: try #require(URL(string: "https://github.com"))
        ),
        account: GitHubAccountIdentity(id: "42", login: "snow-user"),
        authenticationMethod: .deviceFlow,
        clientID: "test-client-id",
        repositorySelection: .allAccessible,
        isEnabled: true
    )
}

private func capabilityPresentationResponses() -> [CapabilityPresentationResponse] {
    [
        CapabilityPresentationResponse(
            json: #"{"id":42,"login":"snow-user","name":"Snow User","avatar_url":null}"#
        ),
        CapabilityPresentationResponse(
            json: #"{"id":42,"login":"snow-user","name":"Snow User","avatar_url":null}"#
        ),
        CapabilityPresentationResponse(
            json: #"{"total_count":1,"installations":[{"id":10,"account":{"id":100,"login":"snow","type":"Organization","avatar_url":null},"repository_selection":"all","permissions":{"actions":"read","checks":"triage"},"suspended_at":null}]}"#
        ),
        CapabilityPresentationResponse(
            json: #"{"total_count":1,"repositories":[{"id":1,"name":"app","full_name":"snow/app","private":true,"owner":{"id":100,"login":"snow","type":"Organization","avatar_url":null},"permissions":{"admin":false,"maintain":false,"push":false,"triage":false,"pull":true}}]}"#
        ),
    ]
}

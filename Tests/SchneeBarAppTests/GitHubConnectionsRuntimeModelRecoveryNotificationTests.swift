@testable import SchneeBar
import Foundation
import SchneeBarCore
import SchneeBarGitHub
import SchneeBarGitHubActivityProvider
import Testing

private actor RecoveryBridgeProfileStore: GitHubConnectionProfileStore {
    private var profiles: [UUID: GitHubConnectionProfile]

    init(_ profile: GitHubConnectionProfile) {
        profiles = [profile.id: profile]
    }

    func loadAll() async throws -> [GitHubConnectionProfile] {
        Array(profiles.values)
    }

    func load(id: UUID) async throws -> GitHubConnectionProfile? {
        profiles[id]
    }

    func save(_ profile: GitHubConnectionProfile) async throws {
        profiles[profile.id] = profile
    }

    func delete(id: UUID) async throws {
        profiles.removeValue(forKey: id)
    }
}

private actor RecoveryBridgeCredentialStore: GitHubCredentialStore {
    private let key: GitHubCredentialKey
    private let credential = GitHubCredential(accessToken: "test-token")

    init(profile: GitHubConnectionProfile) {
        key = GitHubCredentialKey(
            connectionID: profile.id,
            accountID: profile.account.id
        )
    }

    func load(for requested: GitHubCredentialKey) async throws -> GitHubCredential? {
        requested == key ? credential : nil
    }

    func save(_ credential: GitHubCredential, for key: GitHubCredentialKey) async throws {}
    func delete(for key: GitHubCredentialKey) async throws {}
}

private actor RecoveryBridgeTransport: GitHubHTTPTransport {
    private var responses: [(String, Int)]

    init(_ responses: [(String, Int)]) {
        self.responses = responses
    }

    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let response = responses.removeFirst()
        let http = try #require(
            HTTPURLResponse(
                url: request.url!,
                statusCode: response.1,
                httpVersion: "HTTP/1.1",
                headerFields: nil
            )
        )
        return (Data(response.0.utf8), http)
    }
}

private actor RecoveryBridgeWorkflowLoader: GitHubWorkflowRunLoading {
    private var responses: [[GitHubWorkflowRun]]

    init(_ responses: [[GitHubWorkflowRun]]) {
        self.responses = responses
    }

    func workflowRuns(
        connection: GitHubConnection,
        identity: GitHubAccountIdentity,
        clientID: String?,
        repository: GitHubRepositoryAccess,
        query: GitHubWorkflowRunQuery
    ) async throws -> [GitHubWorkflowRun] {
        guard !responses.isEmpty else { return [] }
        return responses.removeFirst()
    }
}

@MainActor
private final class RecoveryBridgeRecorder {
    var events: [DeliveryRecoveryEvent] = []
}

@Test @MainActor
func runtimePublishesDeliveryRecoveryAfterValidProviderResult() async throws {
    let profile = try recoveryBridgeProfile()
    let repositoryURL = try #require(URL(string: "https://github.com/snow/app"))
    let failed = GitHubWorkflowRun(
        id: 101,
        workflowID: 41,
        name: "CI",
        displayTitle: "Build",
        event: "pull_request",
        status: .completed,
        conclusion: .failure,
        runNumber: 10,
        headBranch: "feature",
        headSHA: "failed-sha",
        webURL: repositoryURL.appendingPathComponent("actions/runs/101"),
        pullRequestNumbers: [47],
        createdAt: Date(timeIntervalSince1970: 90),
        updatedAt: Date(timeIntervalSince1970: 100)
    )
    let success = GitHubWorkflowRun(
        id: 102,
        workflowID: 41,
        name: "CI",
        displayTitle: "Build",
        event: "pull_request",
        status: .completed,
        conclusion: .success,
        runNumber: 11,
        headBranch: "feature",
        headSHA: "success-sha",
        webURL: repositoryURL.appendingPathComponent("actions/runs/102"),
        pullRequestNumbers: [47],
        createdAt: Date(timeIntervalSince1970: 190),
        updatedAt: Date(timeIntervalSince1970: 200)
    )
    let workflowLoader = RecoveryBridgeWorkflowLoader([
        [failed],
        [success],
        [success],
    ])
    let credentialStore = RecoveryBridgeCredentialStore(profile: profile)
    let transport = RecoveryBridgeTransport(recoveryBridgeSessionResponses())
    let coordinator = GitHubConnectionSessionCoordinator(
        credentialStore: credentialStore,
        accessClient: GitHubAccessClient(transport: transport)
    )
    let provider = GitHubActivityProvider(
        workflowRunLoader: workflowLoader,
        maximumConcurrentRepositories: 1,
        maximumRepositoriesPerRefresh: 1,
        minimumColdRepositoriesPerRefresh: 1
    )
    let model = GitHubConnectionsRuntimeModel(
        profileStore: RecoveryBridgeProfileStore(profile),
        sessionCoordinator: coordinator,
        activityProvider: provider
    )
    model.profiles = [profile]

    let recorder = RecoveryBridgeRecorder()
    model.onDeliveryRecovery = { event in
        recorder.events.append(event)
    }

    await model.refresh(profileID: profile.id)
    _ = try await model.loadActivityItems()
    #expect(recorder.events.isEmpty)

    _ = try await model.loadActivityItems()
    #expect(recorder.events.count == 1)
    #expect(recorder.events[0].detail.contains("PR #47"))

    _ = try await model.loadActivityItems()
    #expect(recorder.events.count == 1)
}

private func recoveryBridgeProfile() throws -> GitHubConnectionProfile {
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

private func recoveryBridgeSessionResponses() -> [(String, Int)] {
    let user = #"{"id":42,"login":"snow-user","name":"Snow User","avatar_url":null}"#
    let installation = #"{"total_count":1,"installations":[{"id":10,"account":{"id":100,"login":"snow","type":"Organization","avatar_url":null},"repository_selection":"all","permissions":{"actions":"read"},"suspended_at":null}]}"#
    let repositories = #"{"total_count":1,"repositories":[{"id":1,"name":"app","full_name":"snow/app","private":true,"owner":{"id":100,"login":"snow","type":"Organization","avatar_url":null},"permissions":{"admin":false,"maintain":false,"push":false,"triage":false,"pull":true}}]}"#
    return [
        (user, 200),
        (user, 200),
        (installation, 200),
        (repositories, 200),
    ]
}

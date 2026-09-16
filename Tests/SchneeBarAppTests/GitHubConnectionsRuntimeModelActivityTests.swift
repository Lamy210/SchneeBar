@testable import SchneeBar
import Foundation
import SchneeBarCore
import SchneeBarGitHub
import SchneeBarGitHubActivityProvider
import Testing

private actor ActivityRuntimeProfileStore: GitHubConnectionProfileStore {
    private var values: [UUID: GitHubConnectionProfile]

    init(_ profiles: [GitHubConnectionProfile]) {
        values = Dictionary(uniqueKeysWithValues: profiles.map { ($0.id, $0) })
    }

    func loadAll() async throws -> [GitHubConnectionProfile] { Array(values.values) }
    func load(id: UUID) async throws -> GitHubConnectionProfile? { values[id] }
    func save(_ profile: GitHubConnectionProfile) async throws { values[profile.id] = profile }
    func delete(id: UUID) async throws { values.removeValue(forKey: id) }
}

private actor ActivityRuntimeCredentialStore: GitHubCredentialStore {
    private var values: [GitHubCredentialKey: GitHubCredential]

    init(profile: GitHubConnectionProfile) {
        values = [
            GitHubCredentialKey(connectionID: profile.id, accountID: profile.account.id):
                GitHubCredential(accessToken: "activity-token"),
        ]
    }

    func load(for key: GitHubCredentialKey) async throws -> GitHubCredential? { values[key] }
    func save(_ credential: GitHubCredential, for key: GitHubCredentialKey) async throws { values[key] = credential }
    func delete(for key: GitHubCredentialKey) async throws { values.removeValue(forKey: key) }
}

private struct ActivityRuntimeHTTPResponse: Sendable {
    let json: String
    let statusCode: Int

    init(_ json: String, statusCode: Int = 200) {
        self.json = json
        self.statusCode = statusCode
    }
}

private actor ActivityRuntimeTransport: GitHubHTTPTransport {
    private var responses: [ActivityRuntimeHTTPResponse]

    init(_ responses: [ActivityRuntimeHTTPResponse]) {
        self.responses = responses
    }

    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let response = responses.isEmpty
            ? ActivityRuntimeHTTPResponse(#"{"message":"Unexpected request"}"#, statusCode: 500)
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
}

private struct ActivityRuntimeWorkflowLoader: GitHubWorkflowRunLoading {
    let runs: [GitHubWorkflowRun]

    func workflowRuns(
        connection: GitHubConnection,
        identity: GitHubAccountIdentity,
        clientID: String?,
        repository: GitHubRepositoryAccess,
        query: GitHubWorkflowRunQuery
    ) async throws -> [GitHubWorkflowRun] {
        runs
    }
}

private struct ActivityRuntimeReviewLoader: GitHubReviewRequestLoading {
    let requests: [GitHubReviewRequest]

    func reviewRequests(
        connection: GitHubConnection,
        identity: GitHubAccountIdentity,
        clientID: String?,
        repository: GitHubRepositoryAccess
    ) async throws -> [GitHubReviewRequest] {
        requests
    }
}

private struct ActivityRuntimeCheckLoader: GitHubCheckRunLoading {
    func checkRuns(
        connection: GitHubConnection,
        identity: GitHubAccountIdentity,
        clientID: String?,
        repository: GitHubRepositoryAccess,
        headSHA: String
    ) async throws -> [GitHubCheckRun] {
        []
    }
}

@Test @MainActor
func capabilityOnlyActivityBlocksDoNotDowngradeHealthyConnection() async throws {
    let fixture = try activityRuntimeFixture(
        installationPermissions: [:],
        workflowRuns: [],
        reviewRequests: []
    )

    await fixture.model.refresh(profileID: fixture.profile.id)
    #expect(fixture.model.statusByConnectionID[fixture.profile.id] == .connected(repositoryCount: 1))

    let items = try await fixture.model.loadActivityItems()

    #expect(items.isEmpty)
    #expect(fixture.model.statusByConnectionID[fixture.profile.id] == .connected(repositoryCount: 1))
}

@Test @MainActor
func activityRuntimeUsesGlobalInboxOrderingAcrossSources() async throws {
    let repositoryURL = try #require(URL(string: "https://github.com/snow/app"))
    let workflow = GitHubWorkflowRun(
        id: 11,
        workflowID: 100,
        name: "CI",
        displayTitle: "Build",
        event: "push",
        status: .completed,
        conclusion: .failure,
        runNumber: 1,
        headBranch: "main",
        headSHA: String(repeating: "a", count: 40),
        webURL: repositoryURL.appendingPathComponent("actions/runs/11"),
        pullRequestNumbers: [],
        createdAt: Date(timeIntervalSince1970: 100),
        updatedAt: Date(timeIntervalSince1970: 200)
    )
    let review = GitHubReviewRequest(
        number: 7,
        title: "Please review",
        headSHA: String(repeating: "b", count: 40),
        isDraft: false,
        updatedAt: Date(timeIntervalSince1970: 150),
        requestedReviewerIDs: ["42"],
        webURL: repositoryURL.appendingPathComponent("pull/7")
    )
    let fixture = try activityRuntimeFixture(
        installationPermissions: [
            "actions": "read",
            "pull_requests": "read",
            "checks": "read",
        ],
        workflowRuns: [workflow],
        reviewRequests: [review]
    )

    await fixture.model.refresh(profileID: fixture.profile.id)
    let items = try await fixture.model.loadActivityItems()

    #expect(items.map(\.kind) == [.reviewRequest, .workflowRun])
    #expect(items.map(\.id) == ["github-review:1:7", "github-actions:1:11"])
}

@MainActor
private struct ActivityRuntimeFixture {
    let model: GitHubConnectionsRuntimeModel
    let profile: GitHubConnectionProfile
}

@MainActor
private func activityRuntimeFixture(
    installationPermissions: [String: String],
    workflowRuns: [GitHubWorkflowRun],
    reviewRequests: [GitHubReviewRequest]
) throws -> ActivityRuntimeFixture {
    let profile = try activityRuntimeProfile()
    let profileStore = ActivityRuntimeProfileStore([profile])
    let credentialStore = ActivityRuntimeCredentialStore(profile: profile)
    let transport = ActivityRuntimeTransport(
        activityRuntimeSessionResponses(installationPermissions: installationPermissions)
    )
    let coordinator = GitHubConnectionSessionCoordinator(
        credentialStore: credentialStore,
        accessClient: GitHubAccessClient(transport: transport)
    )
    let provider = GitHubActivityProvider(
        workflowRunLoader: ActivityRuntimeWorkflowLoader(runs: workflowRuns),
        reviewRequestLoader: ActivityRuntimeReviewLoader(requests: reviewRequests),
        checkRunLoader: ActivityRuntimeCheckLoader(),
        maximumConcurrentRepositories: 1
    )
    let model = GitHubConnectionsRuntimeModel(
        profileStore: profileStore,
        sessionCoordinator: coordinator,
        activityProvider: provider
    )
    model.profiles = [profile]
    return ActivityRuntimeFixture(model: model, profile: profile)
}

private func activityRuntimeProfile() throws -> GitHubConnectionProfile {
    GitHubConnectionProfile(
        connection: GitHubConnection(
            id: UUID(uuidString: "64000000-0000-0000-0000-000000000001")!,
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

private func activityRuntimeSessionResponses(
    installationPermissions: [String: String]
) -> [ActivityRuntimeHTTPResponse] {
    let permissions = installationPermissions
        .sorted { $0.key < $1.key }
        .map { key, value in "\"\(key)\":\"\(value)\"" }
        .joined(separator: ",")
    let user = #"{"id":42,"login":"snow-user","name":"Snow User","avatar_url":null}"#
    let installation = """
    {"total_count":1,"installations":[{"id":10,"account":{"id":100,"login":"snow","type":"Organization","avatar_url":null},"repository_selection":"all","permissions":{\(permissions)},"suspended_at":null}]}
    """
    let repositories = #"{"total_count":1,"repositories":[{"id":1,"name":"app","full_name":"snow/app","private":true,"owner":{"id":100,"login":"snow","type":"Organization","avatar_url":null},"permissions":{"admin":false,"maintain":false,"push":false,"triage":false,"pull":true}}]}"#
    return [
        ActivityRuntimeHTTPResponse(user),
        ActivityRuntimeHTTPResponse(user),
        ActivityRuntimeHTTPResponse(installation),
        ActivityRuntimeHTTPResponse(repositories),
    ]
}

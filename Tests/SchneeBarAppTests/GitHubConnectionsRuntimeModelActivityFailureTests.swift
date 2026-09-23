@testable import SchneeBar
import Foundation
import SchneeBarCore
import SchneeBarGitHub
import SchneeBarGitHubActivityProvider
import Testing

private actor ActivityFailureProfileStore: GitHubConnectionProfileStore {
    private var profile: GitHubConnectionProfile

    init(_ profile: GitHubConnectionProfile) {
        self.profile = profile
    }

    func loadAll() async throws -> [GitHubConnectionProfile] { [profile] }
    func load(id: UUID) async throws -> GitHubConnectionProfile? { profile.id == id ? profile : nil }
    func save(_ profile: GitHubConnectionProfile) async throws { self.profile = profile }
    func delete(id: UUID) async throws {}
}

private actor ActivityFailureCredentialStore: GitHubCredentialStore {
    private let key: GitHubCredentialKey
    private var credential: GitHubCredential?

    init(profile: GitHubConnectionProfile) {
        key = GitHubCredentialKey(connectionID: profile.id, accountID: profile.account.id)
        credential = GitHubCredential(accessToken: "activity-failure-token")
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

private struct ActivityFailureHTTPResponse: Sendable {
    let json: String
}

private actor ActivityFailureTransport: GitHubHTTPTransport {
    private var responses: [ActivityFailureHTTPResponse]

    init(_ responses: [ActivityFailureHTTPResponse]) {
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

private enum ActivityFailureWorkflowMode: Sendable {
    case success([GitHubWorkflowRun])
    case networkFailure
}

private actor ActivityFailureWorkflowLoader: GitHubWorkflowRunLoading {
    private let mode: ActivityFailureWorkflowMode
    private var calls = 0

    init(_ mode: ActivityFailureWorkflowMode) {
        self.mode = mode
    }

    func workflowRuns(
        connection: GitHubConnection,
        identity: GitHubAccountIdentity,
        clientID: String?,
        repository: GitHubRepositoryAccess,
        query: GitHubWorkflowRunQuery
    ) async throws -> [GitHubWorkflowRun] {
        calls += 1
        switch mode {
        case let .success(runs):
            return runs
        case .networkFailure:
            throw URLError(.notConnectedToInternet)
        }
    }

    func callCount() -> Int { calls }
}

private enum ActivityFailureReviewMode: Sendable {
    case success([GitHubReviewRequest])
    case networkFailure
    case authenticationRequired
}

private actor ActivityFailureReviewLoader: GitHubReviewRequestLoading {
    private let mode: ActivityFailureReviewMode
    private var calls = 0

    init(_ mode: ActivityFailureReviewMode) {
        self.mode = mode
    }

    func reviewRequests(
        connection: GitHubConnection,
        identity: GitHubAccountIdentity,
        clientID: String?,
        repository: GitHubRepositoryAccess
    ) async throws -> [GitHubReviewRequest] {
        calls += 1
        switch mode {
        case let .success(requests):
            return requests
        case .networkFailure:
            throw URLError(.notConnectedToInternet)
        case .authenticationRequired:
            throw GitHubPullRequestListClientError.httpStatus(401)
        }
    }

    func callCount() -> Int { calls }
}

private struct ActivityFailureCheckLoader: GitHubCheckRunLoading {
    func checkRuns(
        connection: GitHubConnection,
        identity: GitHubAccountIdentity,
        clientID: String?,
        repository: GitHubRepositoryAccess,
        headSHA: String
    ) async throws -> [GitHubCheckRun] { [] }
}

@Test @MainActor
func workflowSuccessKeepsConnectionHealthyWhenReviewRequestNetworkFails() async throws {
    let profile = try activityFailureProfile()
    let run = try activityFailureWorkflowRun()
    let workflow = ActivityFailureWorkflowLoader(.success([run]))
    let reviews = ActivityFailureReviewLoader(.networkFailure)
    let fixture = try activityFailureFixture(
        profile: profile,
        permissions: ["actions": "read", "pull_requests": "read"],
        workflow: workflow,
        reviews: reviews
    )

    await fixture.model.refresh(profileID: profile.id)
    let items = try await fixture.model.loadActivityItems()

    #expect(items.map(\.id) == ["github-actions:1:11"])
    #expect(fixture.model.statusByConnectionID[profile.id] == .connected(repositoryCount: 1))
    #expect(await workflow.callCount() == 1)
    #expect(await reviews.callCount() == 1)
}

@Test @MainActor
func allAttemptedActivitySourcesNetworkFailMarksConnectionNetworkUnavailable() async throws {
    let profile = try activityFailureProfile()
    let workflow = ActivityFailureWorkflowLoader(.networkFailure)
    let reviews = ActivityFailureReviewLoader(.networkFailure)
    let fixture = try activityFailureFixture(
        profile: profile,
        permissions: ["actions": "read", "pull_requests": "read"],
        workflow: workflow,
        reviews: reviews
    )

    await fixture.model.refresh(profileID: profile.id)
    do {
        _ = try await fixture.model.loadActivityItems()
        Issue.record("Expected activity loading to report the total network outage")
    } catch {
        // Runtime failure is intentionally surfaced to the widget engine while status keeps the connection diagnosis.
    }

    #expect(fixture.model.statusByConnectionID[profile.id] == .networkUnavailable)
    #expect(await workflow.callCount() == 1)
    #expect(await reviews.callCount() == 1)
}

@Test @MainActor
func activityAuthenticationFailureMarksConnectionAuthenticationRequiredAndResetsProvider() async throws {
    let profile = try activityFailureProfile()
    let workflow = ActivityFailureWorkflowLoader(.success([]))
    let reviews = ActivityFailureReviewLoader(.authenticationRequired)
    let fixture = try activityFailureFixture(
        profile: profile,
        permissions: ["pull_requests": "read"],
        workflow: workflow,
        reviews: reviews
    )

    await fixture.model.refresh(profileID: profile.id)
    do {
        _ = try await fixture.model.loadActivityItems()
    } catch {
        // Authentication failures may also be surfaced to the widget engine.
    }

    #expect(fixture.model.statusByConnectionID[profile.id] == .authenticationRequired)
    #expect(await workflow.callCount() == 0)
    #expect(await reviews.callCount() == 1)

    do {
        _ = try await fixture.model.loadActivityItems()
    } catch {}
    #expect(await reviews.callCount() == 2)
}

@Test @MainActor
func activitySourceSnapshotPreservesPartialGitHubSuccess() async throws {
    let profile = try activityFailureProfile()
    let workflow = ActivityFailureWorkflowLoader(
        .success([try activityFailureWorkflowRun()])
    )
    let reviews = ActivityFailureReviewLoader(.networkFailure)
    let fixture = try activityFailureFixture(
        profile: profile,
        permissions: ["actions": "read", "pull_requests": "read"],
        workflow: workflow,
        reviews: reviews
    )

    await fixture.model.refresh(profileID: profile.id)
    let snapshot = await fixture.model.loadActivitySourceSnapshot()

    #expect(snapshot.status == .available)
    #expect(snapshot.items.map(\.id) == ["github-actions:1:11"])
}

@Test @MainActor
func activitySourceSnapshotNormalizesTotalNetworkFailure() async throws {
    let profile = try activityFailureProfile()
    let workflow = ActivityFailureWorkflowLoader(.networkFailure)
    let reviews = ActivityFailureReviewLoader(.networkFailure)
    let fixture = try activityFailureFixture(
        profile: profile,
        permissions: ["actions": "read", "pull_requests": "read"],
        workflow: workflow,
        reviews: reviews
    )

    await fixture.model.refresh(profileID: profile.id)
    let snapshot = await fixture.model.loadActivitySourceSnapshot()

    #expect(snapshot.status == .temporarilyUnavailable)
    #expect(snapshot.items.isEmpty)
}

@Test @MainActor
func activitySourceSnapshotNormalizesAuthenticationFailure() async throws {
    let profile = try activityFailureProfile()
    let workflow = ActivityFailureWorkflowLoader(.success([]))
    let reviews = ActivityFailureReviewLoader(.authenticationRequired)
    let fixture = try activityFailureFixture(
        profile: profile,
        permissions: ["pull_requests": "read"],
        workflow: workflow,
        reviews: reviews
    )

    await fixture.model.refresh(profileID: profile.id)
    let snapshot = await fixture.model.loadActivitySourceSnapshot()

    #expect(snapshot.status == .authenticationRequired)
    #expect(snapshot.items.isEmpty)
}

@MainActor
private struct ActivityFailureFixture {
    let model: GitHubConnectionsRuntimeModel
}

@MainActor
private func activityFailureFixture(
    profile: GitHubConnectionProfile,
    permissions: [String: String],
    workflow: ActivityFailureWorkflowLoader,
    reviews: ActivityFailureReviewLoader
) throws -> ActivityFailureFixture {
    let profileStore = ActivityFailureProfileStore(profile)
    let credentialStore = ActivityFailureCredentialStore(profile: profile)
    let transport = ActivityFailureTransport(
        activityFailureSessionResponses(permissions: permissions)
    )
    let coordinator = GitHubConnectionSessionCoordinator(
        credentialStore: credentialStore,
        accessClient: GitHubAccessClient(transport: transport)
    )
    let provider = GitHubActivityProvider(
        workflowRunLoader: workflow,
        reviewRequestLoader: reviews,
        checkRunLoader: ActivityFailureCheckLoader(),
        maximumConcurrentRepositories: 1
    )
    let model = GitHubConnectionsRuntimeModel(
        profileStore: profileStore,
        sessionCoordinator: coordinator,
        activityProvider: provider
    )
    model.profiles = [profile]
    return ActivityFailureFixture(model: model)
}

private func activityFailureProfile() throws -> GitHubConnectionProfile {
    GitHubConnectionProfile(
        connection: GitHubConnection(
            id: UUID(uuidString: "66000000-0000-0000-0000-000000000001")!,
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

private func activityFailureWorkflowRun() throws -> GitHubWorkflowRun {
    GitHubWorkflowRun(
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
        webURL: try #require(URL(string: "https://github.com/snow/app/actions/runs/11")),
        pullRequestNumbers: [],
        createdAt: Date(timeIntervalSince1970: 100),
        updatedAt: Date(timeIntervalSince1970: 200)
    )
}

private func activityFailureSessionResponses(
    permissions: [String: String]
) -> [ActivityFailureHTTPResponse] {
    let permissionJSON = permissions
        .sorted { $0.key < $1.key }
        .map { key, value in "\"\(key)\":\"\(value)\"" }
        .joined(separator: ",")

    return [
        ActivityFailureHTTPResponse(
            json: #"{"id":42,"login":"snow-user","name":"Snow User","avatar_url":null}"#
        ),
        ActivityFailureHTTPResponse(
            json: #"{"id":42,"login":"snow-user","name":"Snow User","avatar_url":null}"#
        ),
        ActivityFailureHTTPResponse(
            json: "{\"total_count\":1,\"installations\":[{\"id\":10,\"account\":{\"id\":100,\"login\":\"snow\",\"type\":\"Organization\",\"avatar_url\":null},\"repository_selection\":\"all\",\"permissions\":{\(permissionJSON)},\"suspended_at\":null}]}"
        ),
        ActivityFailureHTTPResponse(
            json: #"{"total_count":1,"repositories":[{"id":1,"name":"app","full_name":"snow/app","private":true,"owner":{"id":100,"login":"snow","type":"Organization","avatar_url":null},"permissions":{"admin":false,"maintain":false,"push":false,"triage":false,"pull":true}}]}"#
        ),
    ]
}

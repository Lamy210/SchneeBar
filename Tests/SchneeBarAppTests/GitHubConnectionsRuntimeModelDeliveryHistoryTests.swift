@testable import SchneeBar
import Foundation
import SchneeBarCore
import SchneeBarGitHub
import SchneeBarGitHubActivityProvider
import Testing

private actor HistoryProfileStore: GitHubConnectionProfileStore {
    private var values: [UUID: GitHubConnectionProfile]

    init(_ profiles: [GitHubConnectionProfile]) {
        values = Dictionary(uniqueKeysWithValues: profiles.map { ($0.id, $0) })
    }

    func loadAll() async throws -> [GitHubConnectionProfile] { Array(values.values) }
    func load(id: UUID) async throws -> GitHubConnectionProfile? { values[id] }
    func save(_ profile: GitHubConnectionProfile) async throws { values[profile.id] = profile }
    func delete(id: UUID) async throws { values.removeValue(forKey: id) }
}

private actor HistoryCredentialStore: GitHubCredentialStore {
    private var values: [GitHubCredentialKey: GitHubCredential]

    init(profile: GitHubConnectionProfile) {
        values = [
            GitHubCredentialKey(connectionID: profile.id, accountID: profile.account.id):
                GitHubCredential(accessToken: "history-token"),
        ]
    }

    func load(for key: GitHubCredentialKey) async throws -> GitHubCredential? { values[key] }
    func save(_ credential: GitHubCredential, for key: GitHubCredentialKey) async throws {
        values[key] = credential
    }
    func delete(for key: GitHubCredentialKey) async throws {
        values.removeValue(forKey: key)
    }
}

private struct HistoryHTTPResponse: Sendable {
    let json: String
    let statusCode: Int

    init(_ json: String, statusCode: Int = 200) {
        self.json = json
        self.statusCode = statusCode
    }
}

private actor HistoryQueueTransport: GitHubHTTPTransport {
    private var responses: [HistoryHTTPResponse]

    init(_ responses: [HistoryHTTPResponse]) {
        self.responses = responses
    }

    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let response = responses.isEmpty
            ? HistoryHTTPResponse(#"{"message":"Unexpected request"}"#, statusCode: 500)
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

private actor RecordingHistoryWorkflowLoader: GitHubWorkflowRunLoading {
    struct Request: Sendable {
        let repository: GitHubRepositoryAccess
        let query: GitHubWorkflowRunQuery
    }

    private var requests: [Request] = []
    private let runs: [GitHubWorkflowRun]

    init(runs: [GitHubWorkflowRun]) {
        self.runs = runs
    }

    func workflowRuns(
        connection: GitHubConnection,
        identity: GitHubAccountIdentity,
        clientID: String?,
        repository: GitHubRepositoryAccess,
        query: GitHubWorkflowRunQuery
    ) async throws -> [GitHubWorkflowRun] {
        requests.append(Request(repository: repository, query: query))
        return runs
    }

    func recordedRequests() -> [Request] { requests }
}

private struct EmptyHistoryReviewLoader: GitHubReviewRequestLoading {
    func reviewRequests(
        connection: GitHubConnection,
        identity: GitHubAccountIdentity,
        clientID: String?,
        repository: GitHubRepositoryAccess
    ) async throws -> [GitHubReviewRequest] { [] }
}

private struct EmptyHistoryCheckLoader: GitHubCheckRunLoading {
    func checkRuns(
        connection: GitHubConnection,
        identity: GitHubAccountIdentity,
        clientID: String?,
        repository: GitHubRepositoryAccess,
        headSHA: String
    ) async throws -> [GitHubCheckRun] { [] }
}

@Test @MainActor
func deliveryHistoryUsesRuntimeRepositoryAndCompletedTwentyQuery() async throws {
    let fixture = try await historyFixture(actionsAvailable: true)
    let loader = RecordingHistoryWorkflowLoader(
        runs: [historyRun(id: 900, branch: "main", conclusion: .success)]
    )

    let history = try await fixture.model.loadDeliveryHistory(
        for: historyActivityItem(),
        workflowRunLoader: loader
    )

    let request = try #require(await loader.recordedRequests().first)
    #expect(request.repository.fullName == "snow/app")
    #expect(request.repository.defaultBranch == "main")
    #expect(request.query.status == .completed)
    #expect(request.query.limit == 20)
    #expect(request.query.branch == nil)
    #expect(request.query.event == nil)
    #expect(history.repository == "snow/app")
    #expect(history.entries.first?.detail == "Succeeded · Default branch · Run #900")
}

@Test @MainActor
func deliveryHistorySkipsFeatureRequestWhenActionsCapabilityIsUnavailable() async throws {
    let fixture = try await historyFixture(actionsAvailable: false)
    let loader = RecordingHistoryWorkflowLoader(runs: [])

    await #expect(throws: (any Error).self) {
        _ = try await fixture.model.loadDeliveryHistory(
            for: historyActivityItem(),
            workflowRunLoader: loader
        )
    }

    #expect(await loader.recordedRequests().isEmpty)
}

@Test @MainActor
func deliveryHistoryRejectsRepositoryOutsideRuntimeInventory() async throws {
    let fixture = try await historyFixture(actionsAvailable: true)
    let loader = RecordingHistoryWorkflowLoader(runs: [])
    var item = historyActivityItem()
    item = ActivityItem(
        id: item.id,
        repository: "snow/missing",
        context: item.context,
        detail: item.detail,
        state: item.state,
        destinationURL: item.destinationURL,
        kind: item.kind,
        updatedAt: item.updatedAt
    )

    await #expect(throws: (any Error).self) {
        _ = try await fixture.model.loadDeliveryHistory(
            for: item,
            workflowRunLoader: loader
        )
    }

    #expect(await loader.recordedRequests().isEmpty)
}

@MainActor
private struct HistoryFixture {
    let model: GitHubConnectionsRuntimeModel
}

@MainActor
private func historyFixture(
    actionsAvailable: Bool
) async throws -> HistoryFixture {
    let profile = try historyProfile()
    let profileStore = HistoryProfileStore([profile])
    let credentialStore = HistoryCredentialStore(profile: profile)
    let accessTransport = HistoryQueueTransport(
        historySessionResponses(actionsAvailable: actionsAvailable)
    )
    let coordinator = GitHubConnectionSessionCoordinator(
        credentialStore: credentialStore,
        accessClient: GitHubAccessClient(transport: accessTransport)
    )
    let emptyWorkflow = RecordingHistoryWorkflowLoader(runs: [])
    let model = GitHubConnectionsRuntimeModel(
        profileStore: profileStore,
        sessionCoordinator: coordinator,
        activityProvider: GitHubActivityProvider(
            workflowRunLoader: emptyWorkflow,
            reviewRequestLoader: EmptyHistoryReviewLoader(),
            checkRunLoader: EmptyHistoryCheckLoader()
        )
    )
    model.profiles = [profile]
    await model.refresh(profileID: profile.id)
    return HistoryFixture(model: model)
}

private func historyProfile() throws -> GitHubConnectionProfile {
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

private func historySessionResponses(
    actionsAvailable: Bool
) -> [HistoryHTTPResponse] {
    let user = #"{"id":42,"login":"snow-user","name":"Snow User","avatar_url":null}"#
    let actionsPermission = actionsAvailable ? #","actions":"read""# : ""
    let installation = """
    {"total_count":1,"installations":[{"id":10,"account":{"id":100,"login":"snow","type":"Organization","avatar_url":null},"repository_selection":"all","permissions":{"pull_requests":"read"\(actionsPermission)},"suspended_at":null}]}
    """
    let repositories = """
    {"total_count":1,"repositories":[{"id":1,"name":"app","full_name":"snow/app","private":true,"owner":{"id":100,"login":"snow","type":"Organization","avatar_url":null},"permissions":{"admin":false,"maintain":false,"push":false,"triage":false,"pull":true},"default_branch":"main"}]}
    """
    return [
        HistoryHTTPResponse(user),
        HistoryHTTPResponse(user),
        HistoryHTTPResponse(installation),
        HistoryHTTPResponse(repositories),
    ]
}

private func historyActivityItem() -> ActivityItem {
    ActivityItem(
        id: "github-actions:1:700",
        repository: "snow/app",
        context: "PR #47 · CI",
        detail: "Succeeded",
        state: .success,
        destinationURL: URL(string: "https://github.com/snow/app/actions/runs/700"),
        kind: .workflowRun,
        updatedAt: Date(timeIntervalSince1970: 200)
    )
}

private func historyRun(
    id: Int64,
    branch: String?,
    conclusion: GitHubWorkflowRunConclusion?
) -> GitHubWorkflowRun {
    let updatedAt = Date(timeIntervalSince1970: TimeInterval(id))
    return GitHubWorkflowRun(
        id: id,
        workflowID: 88,
        name: "CI",
        displayTitle: "CI",
        event: "push",
        status: .completed,
        conclusion: conclusion,
        runNumber: Int(id),
        headBranch: branch,
        headSHA: "head-sha",
        webURL: URL(string: "https://github.com/snow/app/actions/runs/\(id)")!,
        pullRequestNumbers: [],
        createdAt: updatedAt.addingTimeInterval(-30),
        updatedAt: updatedAt
    )
}

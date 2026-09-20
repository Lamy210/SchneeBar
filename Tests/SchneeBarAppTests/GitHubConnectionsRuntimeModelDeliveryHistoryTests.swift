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

private struct ThrowingHistoryWorkflowLoader: GitHubWorkflowRunLoading {
    func workflowRuns(
        connection: GitHubConnection,
        identity: GitHubAccountIdentity,
        clientID: String?,
        repository: GitHubRepositoryAccess,
        query: GitHubWorkflowRunQuery
    ) async throws -> [GitHubWorkflowRun] {
        throw URLError(.timedOut)
    }
}

private actor MemoryDeliveryHistoryStore: DeliveryHistoryStoring {
    private var values: [DeliveryHistoryStorageScope: DeliveryHistorySnapshot]
    private let failRead: Bool
    private let failSave: Bool
    private var deletedSourceIDs: [String] = []

    init(
        values: [DeliveryHistoryStorageScope: DeliveryHistorySnapshot] = [:],
        failRead: Bool = false,
        failSave: Bool = false
    ) {
        self.values = values
        self.failRead = failRead
        self.failSave = failSave
    }

    func load(
        scope: DeliveryHistoryStorageScope
    ) async throws -> DeliveryHistorySnapshot? {
        if failRead {
            throw StoreFailure.read
        }
        return values[scope]
    }

    func save(
        _ snapshot: DeliveryHistorySnapshot,
        scope: DeliveryHistoryStorageScope
    ) async throws {
        if failSave {
            throw StoreFailure.write
        }
        values[scope] = snapshot
    }

    func delete(sourceID: String) async throws {
        deletedSourceIDs.append(sourceID)
        values = values.filter { $0.key.sourceID != sourceID }
    }

    func value(
        scope: DeliveryHistoryStorageScope
    ) -> DeliveryHistorySnapshot? {
        values[scope]
    }

    func deletedSources() -> [String] {
        deletedSourceIDs
    }

    private enum StoreFailure: Error {
        case read
        case write
    }
}

private enum HistoryActionsCapabilityFixture {
    case available
    case unavailable
    case unknown
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
    let fixture = try await historyFixture(actionsCapability: .available)
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
    let fixture = try await historyFixture(actionsCapability: .unavailable)
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
func deliveryHistoryAllowsExplicitRequestWhenActionsCapabilityIsUnknown() async throws {
    let fixture = try await historyFixture(actionsCapability: .unknown)
    let loader = RecordingHistoryWorkflowLoader(
        runs: [historyRun(id: 901, branch: "main", conclusion: .success)]
    )

    let history = try await fixture.model.loadDeliveryHistory(
        for: historyActivityItem(),
        workflowRunLoader: loader
    )

    #expect(history.entries.map(\.id) == ["github-actions:1:901"])
    #expect(await loader.recordedRequests().count == 1)
}

@Test @MainActor
func deliveryHistoryRejectsAmbiguousRuntimeRepositoryMatch() async throws {
    let fixture = try await historyFixture(
        actionsCapability: .available,
        duplicateRepositoryFullName: true
    )
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
    let fixture = try await historyFixture(actionsCapability: .available)
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

@Test @MainActor
func deliveryHistoryAccumulatesUniqueEntriesAcrossExplicitLoads() async throws {
    let store = MemoryDeliveryHistoryStore()
    let fixture = try await historyFixture(
        actionsCapability: .available,
        historyStore: store
    )
    let firstLoader = RecordingHistoryWorkflowLoader(
        runs: (800 ..< 820).map {
            historyRun(id: Int64($0), branch: "main", conclusion: .success)
        }
    )
    let secondLoader = RecordingHistoryWorkflowLoader(
        runs: (820 ..< 840).map {
            historyRun(id: Int64($0), branch: "main", conclusion: .success)
        }
    )

    let first = try await fixture.model.loadDeliveryHistory(
        for: historyActivityItem(),
        workflowRunLoader: firstLoader
    )
    let second = try await fixture.model.loadDeliveryHistory(
        for: historyActivityItem(),
        workflowRunLoader: secondLoader
    )

    let scope = DeliveryHistoryStorageScope(
        sourceID: fixture.profile.id.uuidString,
        repositoryID: "1"
    )
    let persisted = await store.value(scope: scope)

    #expect(first.entries.count == 20)
    #expect(second.entries.count == 40)
    #expect(second.entries.first?.id == "github-actions:1:839")
    #expect(second.entries.last?.id == "github-actions:1:800")
    #expect(persisted == second)
    #expect(await firstLoader.recordedRequests().count == 1)
    #expect(await secondLoader.recordedRequests().count == 1)
}

@Test @MainActor
func deliveryHistoryFallsBackToCacheOnNetworkFailure() async throws {
    let profile = try historyProfile()
    let scope = DeliveryHistoryStorageScope(
        sourceID: profile.id.uuidString,
        repositoryID: "1"
    )
    let cached = DeliveryHistorySnapshot(
        repository: "snow/app",
        entries: [
            DeliveryHistoryEntry(
                id: "cached",
                title: "CI",
                state: .failed,
                occurredAt: Date(timeIntervalSince1970: 100)
            ),
        ]
    )
    let store = MemoryDeliveryHistoryStore(values: [scope: cached])
    let fixture = try await historyFixture(
        actionsCapability: .available,
        historyStore: store
    )

    let history = try await fixture.model.loadDeliveryHistory(
        for: historyActivityItem(),
        workflowRunLoader: ThrowingHistoryWorkflowLoader()
    )

    #expect(history == cached)
}

@Test @MainActor
func deliveryHistoryUsesCacheWhenActionsCapabilityIsUnavailable() async throws {
    let profile = try historyProfile()
    let scope = DeliveryHistoryStorageScope(
        sourceID: profile.id.uuidString,
        repositoryID: "1"
    )
    let cached = DeliveryHistorySnapshot(
        repository: "snow/app",
        entries: [
            DeliveryHistoryEntry(
                id: "cached",
                title: "CI",
                state: .success,
                occurredAt: Date(timeIntervalSince1970: 100)
            ),
        ]
    )
    let store = MemoryDeliveryHistoryStore(values: [scope: cached])
    let fixture = try await historyFixture(
        actionsCapability: .unavailable,
        historyStore: store
    )
    let loader = RecordingHistoryWorkflowLoader(runs: [])

    let history = try await fixture.model.loadDeliveryHistory(
        for: historyActivityItem(),
        workflowRunLoader: loader
    )

    #expect(history == cached)
    #expect(await loader.recordedRequests().isEmpty)
}

@Test @MainActor
func deliveryHistoryPersistenceFailureNeverHidesLiveHistory() async throws {
    let store = MemoryDeliveryHistoryStore(
        failRead: true,
        failSave: true
    )
    let fixture = try await historyFixture(
        actionsCapability: .available,
        historyStore: store
    )
    let loader = RecordingHistoryWorkflowLoader(
        runs: [
            historyRun(id: 950, branch: "main", conclusion: .success),
        ]
    )

    let history = try await fixture.model.loadDeliveryHistory(
        for: historyActivityItem(),
        workflowRunLoader: loader
    )

    #expect(history.entries.map(\.id) == ["github-actions:1:950"])
    #expect(await loader.recordedRequests().count == 1)
}

@Test @MainActor
func disconnectBestEffortDeletesPersistedHistoryForSource() async throws {
    let store = MemoryDeliveryHistoryStore()
    let fixture = try await historyFixture(
        actionsCapability: .available,
        historyStore: store
    )

    await fixture.model.disconnect(profileID: fixture.profile.id)

    #expect(
        await store.deletedSources()
            == [fixture.profile.id.uuidString]
    )
}

@MainActor
private struct HistoryFixture {
    let model: GitHubConnectionsRuntimeModel
    let profile: GitHubConnectionProfile
}

@MainActor
private func historyFixture(
    actionsCapability: HistoryActionsCapabilityFixture,
    duplicateRepositoryFullName: Bool = false,
    historyStore: any DeliveryHistoryStoring = NoopDeliveryHistoryStore()
) async throws -> HistoryFixture {
    let profile = try historyProfile()
    let profileStore = HistoryProfileStore([profile])
    let credentialStore = HistoryCredentialStore(profile: profile)
    let accessTransport = HistoryQueueTransport(
        historySessionResponses(
            actionsCapability: actionsCapability,
            duplicateRepositoryFullName: duplicateRepositoryFullName
        )
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
        ),
        deliveryHistoryStore: historyStore
    )
    model.profiles = [profile]
    await model.refresh(profileID: profile.id)
    return HistoryFixture(
        model: model,
        profile: profile
    )
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
    actionsCapability: HistoryActionsCapabilityFixture,
    duplicateRepositoryFullName: Bool
) -> [HistoryHTTPResponse] {
    let user = #"{"id":42,"login":"snow-user","name":"Snow User","avatar_url":null}"#
    let actionsPermission: String
    let repositoryIsPrivate: Bool
    switch actionsCapability {
    case .available:
        actionsPermission = #","actions":"read""#
        repositoryIsPrivate = true
    case .unavailable:
        actionsPermission = ""
        repositoryIsPrivate = true
    case .unknown:
        actionsPermission = ""
        repositoryIsPrivate = false
    }

    let installation = """
    {"total_count":1,"installations":[{"id":10,"account":{"id":100,"login":"snow","type":"Organization","avatar_url":null},"repository_selection":"all","permissions":{"pull_requests":"read"\(actionsPermission)},"suspended_at":null}]}
    """
    let duplicateRepository = duplicateRepositoryFullName
        ? """
        ,{"id":2,"name":"app-shadow","full_name":"snow/app","private":\(repositoryIsPrivate),"owner":{"id":100,"login":"snow","type":"Organization","avatar_url":null},"permissions":{"admin":false,"maintain":false,"push":false,"triage":false,"pull":true},"default_branch":"main"}
        """
        : ""
    let repositoryCount = duplicateRepositoryFullName ? 2 : 1
    let repositories = """
    {"total_count":\(repositoryCount),"repositories":[{"id":1,"name":"app","full_name":"snow/app","private":\(repositoryIsPrivate),"owner":{"id":100,"login":"snow","type":"Organization","avatar_url":null},"permissions":{"admin":false,"maintain":false,"push":false,"triage":false,"pull":true},"default_branch":"main"}\(duplicateRepository)]}
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

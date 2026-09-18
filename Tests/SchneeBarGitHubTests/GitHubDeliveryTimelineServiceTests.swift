import Foundation
import SchneeBarGitHub
import Testing

private actor TimelineCredentialStore: GitHubCredentialStore {
    private var values: [GitHubCredentialKey: GitHubCredential] = [:]
    private var loadCount = 0

    func load(for key: GitHubCredentialKey) async throws -> GitHubCredential? {
        loadCount += 1
        return values[key]
    }

    func save(_ credential: GitHubCredential, for key: GitHubCredentialKey) async throws {
        values[key] = credential
    }

    func delete(for key: GitHubCredentialKey) async throws {
        values.removeValue(forKey: key)
    }

    func recordedLoadCount() -> Int {
        loadCount
    }
}

private actor TimelineRoutingTransport: GitHubHTTPTransport {
    private let selectedRunJSON: String
    private let pullRequestJSON: String?
    private let baseRunsJSON: String?
    private let associationsBySHA: [String: String]
    private let delayedAssociationSHA: String?
    private let associationDelayNanoseconds: UInt64
    private var requests: [URLRequest] = []
    private var associationStarted = false

    init(
        selectedRunJSON: String,
        pullRequestJSON: String? = nil,
        baseRunsJSON: String? = nil,
        associationsBySHA: [String: String] = [:],
        delayedAssociationSHA: String? = nil,
        associationDelayNanoseconds: UInt64 = 0
    ) {
        self.selectedRunJSON = selectedRunJSON
        self.pullRequestJSON = pullRequestJSON
        self.baseRunsJSON = baseRunsJSON
        self.associationsBySHA = associationsBySHA
        self.delayedAssociationSHA = delayedAssociationSHA
        self.associationDelayNanoseconds = associationDelayNanoseconds
    }

    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        requests.append(request)
        let url = try #require(request.url)
        let path = url.path
        let json: String
        let statusCode: Int

        if path.hasSuffix("/actions/runs/700") {
            json = selectedRunJSON
            statusCode = 200
        } else if path.hasSuffix("/pulls/47"), let pullRequestJSON {
            json = pullRequestJSON
            statusCode = 200
        } else if path.hasSuffix("/actions/runs"), let baseRunsJSON {
            json = baseRunsJSON
            statusCode = 200
        } else if let sha = associationSHA(from: path), let associationJSON = associationsBySHA[sha] {
            associationStarted = true
            if sha == delayedAssociationSHA, associationDelayNanoseconds > 0 {
                try await Task.sleep(nanoseconds: associationDelayNanoseconds)
            }
            json = associationJSON
            statusCode = 200
        } else {
            json = #"{"message":"Unexpected request"}"#
            statusCode = 500
        }

        let response = try #require(
            HTTPURLResponse(
                url: url,
                statusCode: statusCode,
                httpVersion: "HTTP/1.1",
                headerFields: nil
            )
        )
        return (Data(json.utf8), response)
    }

    func recordedRequests() -> [URLRequest] {
        requests
    }

    func waitUntilAssociationStarts() async {
        while !associationStarted {
            await Task.yield()
        }
    }

    private func associationSHA(from path: String) -> String? {
        let components = path.split(separator: "/").map(String.init)
        guard let commitsIndex = components.firstIndex(of: "commits"),
              components.indices.contains(commitsIndex + 2),
              components[commitsIndex + 2] == "pulls"
        else {
            return nil
        }
        return components[commitsIndex + 1]
    }
}

@Test
func timelineEvidenceAuthorizesOnceAndReturnsEarlyWithoutPullRequestIdentity() async throws {
    let fixture = try await timelineFixture(
        transport: TimelineRoutingTransport(
            selectedRunJSON: workflowRunJSON(id: 700, pullRequestNumbers: [])
        )
    )

    let evidence = try await fixture.service.timelineEvidence(
        connection: fixture.connection,
        identity: fixture.identity,
        clientID: nil,
        repository: fixture.repository,
        runID: 700
    )

    #expect(evidence.selectedRun.id == 700)
    #expect(evidence.pullRequest == nil)
    #expect(evidence.baseRuns.isEmpty)
    #expect(evidence.associatedPullRequestNumbersByRunID.isEmpty)
    #expect(await fixture.store.recordedLoadCount() == 1)
    #expect(await fixture.transport.recordedRequests().count == 1)
}

@Test
func timelineEvidenceReturnsEarlyForAmbiguousPullRequestIdentity() async throws {
    let fixture = try await timelineFixture(
        transport: TimelineRoutingTransport(
            selectedRunJSON: workflowRunJSON(id: 700, pullRequestNumbers: [47, 48])
        )
    )

    let evidence = try await fixture.service.timelineEvidence(
        connection: fixture.connection,
        identity: fixture.identity,
        clientID: nil,
        repository: fixture.repository,
        runID: 700
    )

    #expect(evidence.pullRequest == nil)
    #expect(evidence.baseRuns.isEmpty)
    #expect(await fixture.transport.recordedRequests().count == 1)
}

@Test
func timelineEvidenceReturnsEarlyForUnmergedPullRequest() async throws {
    let transport = TimelineRoutingTransport(
        selectedRunJSON: workflowRunJSON(id: 700, pullRequestNumbers: [47]),
        pullRequestJSON: pullRequestJSON(merged: false, mergedAt: nil)
    )
    let fixture = try await timelineFixture(transport: transport)

    let evidence = try await fixture.service.timelineEvidence(
        connection: fixture.connection,
        identity: fixture.identity,
        clientID: nil,
        repository: fixture.repository,
        runID: 700
    )

    #expect(evidence.pullRequest?.number == 47)
    #expect(evidence.pullRequest?.isMerged == false)
    #expect(evidence.baseRuns.isEmpty)
    #expect(evidence.associatedPullRequestNumbersByRunID.isEmpty)
    #expect(await transport.recordedRequests().count == 2)
}

@Test
func timelineEvidenceUsesBaseBranchLimitAndDeterministicCandidateOrder() async throws {
    let baseRuns = workflowRunsJSON([
        workflowRunJSON(id: 801, workflowID: 99, headBranch: "main", headSHA: "sha-new-other", updatedAt: "2026-09-18T03:00:00Z"),
        workflowRunJSON(id: 802, workflowID: 88, headBranch: "main", headSHA: "sha-old-same", updatedAt: "2026-09-18T01:00:00Z"),
        workflowRunJSON(id: 803, workflowID: 88, headBranch: "main", headSHA: "sha-new-same", updatedAt: "2026-09-18T02:00:00Z"),
        workflowRunJSON(id: 804, workflowID: 88, headBranch: "feature", headSHA: "sha-wrong-branch", updatedAt: "2026-09-18T04:00:00Z"),
        workflowRunJSON(id: 700, workflowID: 88, headBranch: "main", headSHA: "selected-sha", pullRequestNumbers: [47], updatedAt: "2026-09-18T05:00:00Z"),
    ])
    let transport = TimelineRoutingTransport(
        selectedRunJSON: workflowRunJSON(id: 700, workflowID: 88, pullRequestNumbers: [47]),
        pullRequestJSON: pullRequestJSON(),
        baseRunsJSON: baseRuns,
        associationsBySHA: [
            "sha-new-same": #"[]"#,
            "sha-old-same": #"[{"number":47}]"#,
            "sha-new-other": #"[{"number":47}]"#,
        ]
    )
    let fixture = try await timelineFixture(transport: transport)

    let evidence = try await fixture.service.timelineEvidence(
        connection: fixture.connection,
        identity: fixture.identity,
        clientID: nil,
        repository: fixture.repository,
        runID: 700
    )

    #expect(evidence.baseRuns.map(\.id) == [803, 802, 801])
    #expect(evidence.associatedPullRequestNumbersByRunID[803] == [])
    #expect(evidence.associatedPullRequestNumbersByRunID[802] == [47])
    #expect(evidence.associatedPullRequestNumbersByRunID[801] == nil)

    let requests = await transport.recordedRequests()
    let baseRequest = try #require(requests.first(where: { $0.url?.path.hasSuffix("/actions/runs") == true }))
    #expect(queryValue("branch", in: baseRequest) == "main")
    #expect(queryValue("per_page", in: baseRequest) == "20")
    #expect(queryValue("page", in: baseRequest) == "1")

    let associationPaths = requests.compactMap { request -> String? in
        guard let path = request.url?.path, path.contains("/commits/") else { return nil }
        return path
    }
    #expect(associationPaths.count == 2)
    #expect(associationPaths[0].contains("/commits/sha-new-same/pulls"))
    #expect(associationPaths[1].contains("/commits/sha-old-same/pulls"))
}

@Test
func timelineEvidenceDeduplicatesCommitAssociationRequestsBySHA() async throws {
    let transport = TimelineRoutingTransport(
        selectedRunJSON: workflowRunJSON(id: 700, pullRequestNumbers: [47]),
        pullRequestJSON: pullRequestJSON(),
        baseRunsJSON: workflowRunsJSON([
            workflowRunJSON(id: 801, workflowID: 88, headSHA: "duplicate-sha", updatedAt: "2026-09-18T03:00:00Z"),
            workflowRunJSON(id: 802, workflowID: 88, headSHA: "duplicate-sha", updatedAt: "2026-09-18T02:00:00Z"),
            workflowRunJSON(id: 803, workflowID: 88, headSHA: "unique-sha", updatedAt: "2026-09-18T01:00:00Z"),
        ]),
        associationsBySHA: [
            "duplicate-sha": #"[]"#,
            "unique-sha": #"[{"number":47}]"#,
        ]
    )
    let fixture = try await timelineFixture(transport: transport)

    let evidence = try await fixture.service.timelineEvidence(
        connection: fixture.connection,
        identity: fixture.identity,
        clientID: nil,
        repository: fixture.repository,
        runID: 700
    )

    #expect(evidence.associatedPullRequestNumbersByRunID[801] == [])
    #expect(evidence.associatedPullRequestNumbersByRunID[802] == [])
    #expect(evidence.associatedPullRequestNumbersByRunID[803] == [47])

    let associationRequests = await transport.recordedRequests().filter {
        $0.url?.path.contains("/commits/") == true
    }
    #expect(associationRequests.count == 2)
}

@Test
func timelineEvidenceCapsAssociationRequestsAtFour() async throws {
    let runs = (1 ... 5).map { index in
        workflowRunJSON(
            id: Int64(800 + index),
            workflowID: 88,
            headSHA: "sha-\(index)",
            updatedAt: "2026-09-18T0\(6 - index):00:00Z"
        )
    }
    let associations = Dictionary(uniqueKeysWithValues: (1 ... 5).map { index in
        ("sha-\(index)", #"[{"number":99}]"#)
    })
    let transport = TimelineRoutingTransport(
        selectedRunJSON: workflowRunJSON(id: 700, pullRequestNumbers: [47]),
        pullRequestJSON: pullRequestJSON(),
        baseRunsJSON: workflowRunsJSON(runs),
        associationsBySHA: associations
    )
    let fixture = try await timelineFixture(transport: transport)

    let evidence = try await fixture.service.timelineEvidence(
        connection: fixture.connection,
        identity: fixture.identity,
        clientID: nil,
        repository: fixture.repository,
        runID: 700
    )

    let requests = await transport.recordedRequests()
    let associationRequests = requests.filter { $0.url?.path.contains("/commits/") == true }
    #expect(associationRequests.count == 4)
    #expect(requests.count == 7)
    #expect(evidence.associatedPullRequestNumbersByRunID.count == 4)
    #expect(evidence.associatedPullRequestNumbersByRunID[805] == nil)
}

@Test
func timelineEvidenceRequestCapIncludesAssociationPagination() async throws {
    let runs = (1 ... 4).map { index in
        workflowRunJSON(
            id: Int64(800 + index),
            workflowID: 88,
            headSHA: "full-page-sha-\(index)",
            updatedAt: "2026-09-18T0\(6 - index):00:00Z"
        )
    }
    let fullAssociationPage = "["
        + (100 ... 199).map { "{\"number\":\($0)}" }.joined(separator: ",")
        + "]"
    let associations = Dictionary(uniqueKeysWithValues: (1 ... 4).map { index in
        ("full-page-sha-\(index)", fullAssociationPage)
    })
    let transport = TimelineRoutingTransport(
        selectedRunJSON: workflowRunJSON(id: 700, pullRequestNumbers: [47]),
        pullRequestJSON: pullRequestJSON(),
        baseRunsJSON: workflowRunsJSON(runs),
        associationsBySHA: associations
    )
    let fixture = try await timelineFixture(transport: transport)

    _ = try await fixture.service.timelineEvidence(
        connection: fixture.connection,
        identity: fixture.identity,
        clientID: nil,
        repository: fixture.repository,
        runID: 700
    )

    let requests = await transport.recordedRequests()
    let associationRequests = requests.filter { $0.url?.path.contains("/commits/") == true }

    #expect(associationRequests.count == 4)
    #expect(requests.count == 7)
    #expect(associationRequests.allSatisfy { queryValue("page", in: $0) == "1" })
}

@Test
func timelineEvidenceCancellationStopsLaterAssociationRequests() async throws {
    let transport = TimelineRoutingTransport(
        selectedRunJSON: workflowRunJSON(id: 700, pullRequestNumbers: [47]),
        pullRequestJSON: pullRequestJSON(),
        baseRunsJSON: workflowRunsJSON([
            workflowRunJSON(id: 801, workflowID: 88, headSHA: "slow-sha", updatedAt: "2026-09-18T03:00:00Z"),
            workflowRunJSON(id: 802, workflowID: 88, headSHA: "later-sha", updatedAt: "2026-09-18T02:00:00Z"),
        ]),
        associationsBySHA: [
            "slow-sha": #"[]"#,
            "later-sha": #"[{"number":47}]"#,
        ],
        delayedAssociationSHA: "slow-sha",
        associationDelayNanoseconds: 5_000_000_000
    )
    let fixture = try await timelineFixture(transport: transport)

    let task = Task {
        try await fixture.service.timelineEvidence(
            connection: fixture.connection,
            identity: fixture.identity,
            clientID: nil,
            repository: fixture.repository,
            runID: 700
        )
    }

    await transport.waitUntilAssociationStarts()
    task.cancel()

    await #expect(throws: CancellationError.self) {
        try await task.value
    }

    let associationRequests = await transport.recordedRequests().filter {
        $0.url?.path.contains("/commits/") == true
    }
    #expect(associationRequests.count == 1)
    #expect(associationRequests[0].url?.path.contains("/commits/slow-sha/pulls") == true)
}

private struct TimelineFixture {
    let service: GitHubDeliveryTimelineService
    let store: TimelineCredentialStore
    let transport: TimelineRoutingTransport
    let connection: GitHubConnection
    let identity: GitHubAccountIdentity
    let repository: GitHubRepositoryAccess
}

private func timelineFixture(
    transport: TimelineRoutingTransport
) async throws -> TimelineFixture {
    let connection = GitHubConnection(
        id: UUID(uuidString: "11111111-2222-3333-4444-555555555555")!,
        displayName: "GitHub.com",
        deploymentKind: .githubDotCom,
        webBaseURL: try #require(URL(string: "https://github.com"))
    )
    let identity = GitHubAccountIdentity(id: "100", login: "octocat")
    let repository = GitHubRepositoryAccess(
        id: 42,
        name: "project",
        fullName: "octocat/project",
        isPrivate: false,
        webURL: try #require(URL(string: "https://github.com/octocat/project")),
        ownerLogin: "octocat",
        permissions: GitHubRepositoryPermissions(pull: true)
    )
    let store = TimelineCredentialStore()
    try await store.save(
        GitHubCredential(accessToken: "ghu_timeline"),
        for: GitHubCredentialKey(connectionID: connection.id, accountID: identity.id)
    )
    let coordinator = GitHubConnectionSessionCoordinator(credentialStore: store)
    let service = GitHubDeliveryTimelineService(
        sessionCoordinator: coordinator,
        actionsClient: GitHubActionsClient(transport: transport),
        pullRequestClient: GitHubPullRequestMetadataClient(transport: transport),
        commitPullRequestClient: GitHubCommitPullRequestClient(transport: transport)
    )
    return TimelineFixture(
        service: service,
        store: store,
        transport: transport,
        connection: connection,
        identity: identity,
        repository: repository
    )
}

private func workflowRunJSON(
    id: Int64,
    workflowID: Int64 = 88,
    headBranch: String? = "main",
    headSHA: String = "selected-sha",
    pullRequestNumbers: [Int] = [],
    updatedAt: String = "2026-09-18T03:00:00Z"
) -> String {
    let branchJSON = headBranch.map { "\"\($0)\"" } ?? "null"
    let pulls = pullRequestNumbers.map { "{\"number\":\($0)}" }.joined(separator: ",")
    return """
    {"id":\(id),"workflow_id":\(workflowID),"name":"CI","display_title":"CI","event":"push","status":"completed","conclusion":"success","run_number":1,"head_branch":\(branchJSON),"head_sha":"\(headSHA)","pull_requests":[\(pulls)],"created_at":"2026-09-18T00:00:00Z","updated_at":"\(updatedAt)","html_url":"https://evil.example/run"}
    """
}

private func workflowRunsJSON(_ runs: [String]) -> String {
    "{\"total_count\":\(runs.count),\"workflow_runs\":[\(runs.joined(separator: ","))]}"
}

private func pullRequestJSON(
    merged: Bool = true,
    mergedAt: String? = "2026-09-18T00:30:00Z"
) -> String {
    let mergedAtJSON = mergedAt.map { "\"\($0)\"" } ?? "null"
    return """
    {"number":47,"state":"closed","draft":false,"merged":\(merged),"merge_commit_sha":"merge-sha","head":{"ref":"feature/timeline","sha":"selected-sha"},"base":{"ref":"main","sha":"base-sha"},"updated_at":"2026-09-18T00:31:00Z","merged_at":\(mergedAtJSON),"html_url":"https://evil.example/pr"}
    """
}

private func queryValue(_ name: String, in request: URLRequest) -> String? {
    guard let url = request.url,
          let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
    else {
        return nil
    }
    return components.queryItems?.first(where: { $0.name == name })?.value
}

@testable import SchneeBar
import Foundation
import SchneeBarCore
import SchneeBarGitHub
import SchneeBarGitHubActivityProvider
import Testing

private actor DetailProfileStore: GitHubConnectionProfileStore {
    private var values: [UUID: GitHubConnectionProfile]

    init(_ profiles: [GitHubConnectionProfile]) {
        values = Dictionary(uniqueKeysWithValues: profiles.map { ($0.id, $0) })
    }

    func loadAll() async throws -> [GitHubConnectionProfile] { Array(values.values) }
    func load(id: UUID) async throws -> GitHubConnectionProfile? { values[id] }
    func save(_ profile: GitHubConnectionProfile) async throws { values[profile.id] = profile }
    func delete(id: UUID) async throws { values.removeValue(forKey: id) }
}

private actor DetailCredentialStore: GitHubCredentialStore {
    private var values: [GitHubCredentialKey: GitHubCredential]

    init(profile: GitHubConnectionProfile) {
        values = [
            GitHubCredentialKey(connectionID: profile.id, accountID: profile.account.id):
                GitHubCredential(accessToken: "detail-token"),
        ]
    }

    func load(for key: GitHubCredentialKey) async throws -> GitHubCredential? { values[key] }
    func save(_ credential: GitHubCredential, for key: GitHubCredentialKey) async throws { values[key] = credential }
    func delete(for key: GitHubCredentialKey) async throws { values.removeValue(forKey: key) }
}

private struct DetailHTTPResponse: Sendable {
    let json: String
    let statusCode: Int

    init(_ json: String, statusCode: Int = 200) {
        self.json = json
        self.statusCode = statusCode
    }
}

private actor DetailQueueTransport: GitHubHTTPTransport {
    private var responses: [DetailHTTPResponse]

    init(_ responses: [DetailHTTPResponse]) {
        self.responses = responses
    }

    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let response = responses.isEmpty
            ? DetailHTTPResponse(#"{"message":"Unexpected request"}"#, statusCode: 500)
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

private struct DetailWorkflowLoader: GitHubWorkflowRunLoading {
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

private struct DetailReviewLoader: GitHubReviewRequestLoading {
    func reviewRequests(
        connection: GitHubConnection,
        identity: GitHubAccountIdentity,
        clientID: String?,
        repository: GitHubRepositoryAccess
    ) async throws -> [GitHubReviewRequest] {
        []
    }
}

private struct DetailCheckLoader: GitHubCheckRunLoading {
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

private enum DetailTimelineOutcome: Sendable {
    case evidence(GitHubDeliveryTimelineEvidence)
    case failure
}

private enum DetailTimelineError: Error {
    case failed
}

private actor DetailTimelineLoader: GitHubDeliveryTimelineLoading {
    private let outcome: DetailTimelineOutcome
    private var callCount = 0

    init(_ outcome: DetailTimelineOutcome) {
        self.outcome = outcome
    }

    func timelineEvidence(
        connection: GitHubConnection,
        identity: GitHubAccountIdentity,
        clientID: String?,
        repository: GitHubRepositoryAccess,
        runID: Int64
    ) async throws -> GitHubDeliveryTimelineEvidence {
        callCount += 1
        switch outcome {
        case let .evidence(evidence):
            return evidence
        case .failure:
            throw DetailTimelineError.failed
        }
    }

    func calls() -> Int { callCount }
}

private enum DetailDeploymentOutcome: Sendable {
    case evidence(GitHubDeploymentTimelineEvidence)
    case failure
    case cancellation
}

private actor DetailDeploymentLoader: GitHubDeploymentTimelineLoading {
    private let outcome: DetailDeploymentOutcome
    private var requestedSHAs: [String] = []

    init(_ outcome: DetailDeploymentOutcome) {
        self.outcome = outcome
    }

    func deploymentEvidence(
        connection: GitHubConnection,
        identity: GitHubAccountIdentity,
        clientID: String?,
        repository: GitHubRepositoryAccess,
        exactSHA: String
    ) async throws -> GitHubDeploymentTimelineEvidence {
        requestedSHAs.append(exactSHA)
        switch outcome {
        case let .evidence(evidence):
            return evidence
        case .failure:
            throw DetailTimelineError.failed
        case .cancellation:
            throw CancellationError()
        }
    }

    func calls() -> Int { requestedSHAs.count }
    func SHAs() -> [String] { requestedSHAs }
}

private enum DetailDeploymentCapabilityFixture {
    case available
    case unavailable
    case unknown
}

@Test @MainActor
func activityDetailCombinesJobsAndCorrelatedTimeline() async throws {
    let fixture = try await detailFixture(jobStatusCode: 200)
    let timelineLoader = DetailTimelineLoader(.evidence(try correlatedDetailEvidence()))
    let deploymentLoader = DetailDeploymentLoader(
        .evidence(GitHubDeploymentTimelineEvidence(exactSHA: "landed-sha", deployments: []))
    )

    let detail = try await fixture.model.loadActivityDetail(
        for: detailActivityItem(),
        jobService: fixture.jobService,
        timelineLoader: timelineLoader,
        deploymentTimelineLoader: deploymentLoader,
        timelineBuilder: GitHubDeliveryTimelineBuilder()
    )

    #expect(detail.rows.map(\.id) == ["7001"])
    #expect(detail.deliveryTimeline?.status == .correlated)
    #expect(detail.deliveryTimeline?.confidence == .exact)
    #expect(detail.deliveryTimeline?.events.map(\.kind) == [.pullRequest, .merge, .execution])
    #expect(await timelineLoader.calls() == 1)
    #expect(await deploymentLoader.SHAs() == ["landed-sha"])
}

@Test @MainActor
func activityDetailPreservesJobsWhenTimelineEvidenceIsUnavailable() async throws {
    let fixture = try await detailFixture(jobStatusCode: 200)
    let selectedRun = detailRun(
        id: 700,
        branch: "feature/timeline",
        headSHA: "final-head",
        pullRequestNumbers: []
    )
    let timelineLoader = DetailTimelineLoader(
        .evidence(
            GitHubDeliveryTimelineEvidence(
                selectedRun: selectedRun,
                pullRequest: nil,
                baseRuns: [],
                associatedPullRequestNumbersByRunID: [:]
            )
        )
    )
    let deploymentLoader = DetailDeploymentLoader(
        .evidence(GitHubDeploymentTimelineEvidence(exactSHA: "unused", deployments: []))
    )

    let detail = try await fixture.model.loadActivityDetail(
        for: detailActivityItem(),
        jobService: fixture.jobService,
        timelineLoader: timelineLoader,
        deploymentTimelineLoader: deploymentLoader,
        timelineBuilder: GitHubDeliveryTimelineBuilder()
    )

    #expect(detail.rows.map(\.id) == ["7001"])
    #expect(detail.deliveryTimeline?.status == .evidenceUnavailable)
    #expect(detail.deliveryTimeline?.confidence == .unknown)
    #expect(detail.deliveryTimeline?.events.isEmpty == true)
    #expect(await deploymentLoader.calls() == 0)
}

@Test @MainActor
func activityDetailConvertsTimelineFailureWithoutHidingJobs() async throws {
    let fixture = try await detailFixture(jobStatusCode: 200)
    let timelineLoader = DetailTimelineLoader(.failure)
    let deploymentLoader = DetailDeploymentLoader(
        .evidence(GitHubDeploymentTimelineEvidence(exactSHA: "unused", deployments: []))
    )

    let detail = try await fixture.model.loadActivityDetail(
        for: detailActivityItem(),
        jobService: fixture.jobService,
        timelineLoader: timelineLoader,
        deploymentTimelineLoader: deploymentLoader,
        timelineBuilder: GitHubDeliveryTimelineBuilder()
    )

    #expect(detail.rows.map(\.id) == ["7001"])
    #expect(detail.deliveryTimeline?.status == .temporarilyUnavailable)
    #expect(detail.deliveryTimeline?.confidence == .unknown)
    #expect(detail.deliveryTimeline?.events.isEmpty == true)
    #expect(await timelineLoader.calls() == 1)
    #expect(await deploymentLoader.calls() == 0)
}

@Test @MainActor
func activityDetailJobFailureStillFailsBeforeTimelineLoading() async throws {
    let fixture = try await detailFixture(jobStatusCode: 500)
    let timelineLoader = DetailTimelineLoader(.evidence(try correlatedDetailEvidence()))
    let deploymentLoader = DetailDeploymentLoader(
        .evidence(GitHubDeploymentTimelineEvidence(exactSHA: "unused", deployments: []))
    )

    await #expect(throws: (any Error).self) {
        try await fixture.model.loadActivityDetail(
            for: detailActivityItem(),
            jobService: fixture.jobService,
            timelineLoader: timelineLoader,
            deploymentTimelineLoader: deploymentLoader,
            timelineBuilder: GitHubDeliveryTimelineBuilder()
        )
    }

    #expect(await timelineLoader.calls() == 0)
    #expect(await deploymentLoader.calls() == 0)
}

@Test @MainActor
func activityDetailAppendsDeploymentEvidenceUsingCorrelatedBaseSHA() async throws {
    let fixture = try await detailFixture(jobStatusCode: 200)
    let timelineLoader = DetailTimelineLoader(.evidence(try correlatedDetailEvidence()))
    let deploymentLoader = DetailDeploymentLoader(.evidence(detailDeploymentEvidence()))

    let detail = try await fixture.model.loadActivityDetail(
        for: detailActivityItem(),
        jobService: fixture.jobService,
        timelineLoader: timelineLoader,
        deploymentTimelineLoader: deploymentLoader,
        timelineBuilder: GitHubDeliveryTimelineBuilder()
    )

    #expect(detail.rows.map(\.id) == ["7001"])
    #expect(detail.deliveryTimeline?.events.map(\.kind) == [
        .pullRequest, .merge, .execution, .deployment,
    ])
    #expect(detail.deliveryTimeline?.events.last?.title == "Deployment · production")
    #expect(await deploymentLoader.SHAs() == ["landed-sha"])
}

@Test @MainActor
func activityDetailPreservesCorrelatedTimelineWhenDeploymentLoadingFails() async throws {
    let fixture = try await detailFixture(jobStatusCode: 200)
    let timelineLoader = DetailTimelineLoader(.evidence(try correlatedDetailEvidence()))
    let deploymentLoader = DetailDeploymentLoader(.failure)

    let detail = try await fixture.model.loadActivityDetail(
        for: detailActivityItem(),
        jobService: fixture.jobService,
        timelineLoader: timelineLoader,
        deploymentTimelineLoader: deploymentLoader,
        timelineBuilder: GitHubDeliveryTimelineBuilder()
    )

    #expect(detail.rows.map(\.id) == ["7001"])
    #expect(detail.deliveryTimeline?.status == .correlated)
    #expect(detail.deliveryTimeline?.events.map(\.kind) == [
        .pullRequest, .merge, .execution,
    ])
    #expect(await deploymentLoader.calls() == 1)
}

@Test @MainActor
func activityDetailSkipsDeploymentWhenCapabilityIsUnavailable() async throws {
    let fixture = try await detailFixture(
        jobStatusCode: 200,
        deploymentCapability: .unavailable
    )
    let timelineLoader = DetailTimelineLoader(.evidence(try correlatedDetailEvidence()))
    let deploymentLoader = DetailDeploymentLoader(.evidence(detailDeploymentEvidence()))

    let detail = try await fixture.model.loadActivityDetail(
        for: detailActivityItem(),
        jobService: fixture.jobService,
        timelineLoader: timelineLoader,
        deploymentTimelineLoader: deploymentLoader,
        timelineBuilder: GitHubDeliveryTimelineBuilder()
    )

    #expect(detail.deliveryTimeline?.events.map(\.kind) == [
        .pullRequest, .merge, .execution,
    ])
    #expect(await deploymentLoader.calls() == 0)
}

@Test @MainActor
func activityDetailAllowsDeploymentRequestWhenCapabilityIsUnknown() async throws {
    let fixture = try await detailFixture(
        jobStatusCode: 200,
        deploymentCapability: .unknown
    )
    let timelineLoader = DetailTimelineLoader(.evidence(try correlatedDetailEvidence()))
    let deploymentLoader = DetailDeploymentLoader(.evidence(detailDeploymentEvidence()))

    let detail = try await fixture.model.loadActivityDetail(
        for: detailActivityItem(),
        jobService: fixture.jobService,
        timelineLoader: timelineLoader,
        deploymentTimelineLoader: deploymentLoader,
        timelineBuilder: GitHubDeliveryTimelineBuilder()
    )

    #expect(detail.deliveryTimeline?.events.last?.kind == .deployment)
    #expect(await deploymentLoader.SHAs() == ["landed-sha"])
}

@Test @MainActor
func activityDetailPropagatesDeploymentCancellation() async throws {
    let fixture = try await detailFixture(jobStatusCode: 200)
    let timelineLoader = DetailTimelineLoader(.evidence(try correlatedDetailEvidence()))
    let deploymentLoader = DetailDeploymentLoader(.cancellation)

    await #expect(throws: CancellationError.self) {
        try await fixture.model.loadActivityDetail(
            for: detailActivityItem(),
            jobService: fixture.jobService,
            timelineLoader: timelineLoader,
            deploymentTimelineLoader: deploymentLoader,
            timelineBuilder: GitHubDeliveryTimelineBuilder()
        )
    }

    #expect(await deploymentLoader.calls() == 1)
}

@MainActor
private struct DetailFixture {
    let model: GitHubConnectionsRuntimeModel
    let jobService: GitHubWorkflowJobService
}

@MainActor
private func detailFixture(
    jobStatusCode: Int,
    deploymentCapability: DetailDeploymentCapabilityFixture = .available
) async throws -> DetailFixture {
    let profile = try detailProfile()
    let profileStore = DetailProfileStore([profile])
    let credentialStore = DetailCredentialStore(profile: profile)
    let accessTransport = DetailQueueTransport(
        detailSessionResponses(deploymentCapability: deploymentCapability)
    )
    let coordinator = GitHubConnectionSessionCoordinator(
        credentialStore: credentialStore,
        accessClient: GitHubAccessClient(transport: accessTransport)
    )
    let model = GitHubConnectionsRuntimeModel(
        profileStore: profileStore,
        sessionCoordinator: coordinator,
        activityProvider: GitHubActivityProvider(
            workflowRunLoader: DetailWorkflowLoader(),
            reviewRequestLoader: DetailReviewLoader(),
            checkRunLoader: DetailCheckLoader()
        )
    )
    model.profiles = [profile]
    await model.refresh(profileID: profile.id)

    let jobTransport = DetailQueueTransport([
        DetailHTTPResponse(
            #"{"total_count":1,"jobs":[{"id":7001,"run_id":700,"name":"Build","status":"completed","conclusion":"success","started_at":"2026-09-18T00:00:00Z","completed_at":"2026-09-18T00:00:30Z","labels":[],"steps":[]}]}"#,
            statusCode: jobStatusCode
        ),
    ])
    let jobService = GitHubWorkflowJobService(
        sessionCoordinator: coordinator,
        jobsClient: GitHubActionsJobsClient(transport: jobTransport)
    )
    return DetailFixture(model: model, jobService: jobService)
}

private func detailProfile() throws -> GitHubConnectionProfile {
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

private func detailSessionResponses(
    deploymentCapability: DetailDeploymentCapabilityFixture
) -> [DetailHTTPResponse] {
    let user = #"{"id":42,"login":"snow-user","name":"Snow User","avatar_url":null}"#

    let permissions: String
    let repositoryIsPrivate: Bool
    switch deploymentCapability {
    case .available:
        permissions = #"{"actions":"read","pull_requests":"read","deployments":"read"}"#
        repositoryIsPrivate = true
    case .unavailable:
        permissions = #"{"actions":"read","pull_requests":"read"}"#
        repositoryIsPrivate = true
    case .unknown:
        permissions = #"{"actions":"read","pull_requests":"read"}"#
        repositoryIsPrivate = false
    }

    let installation = """
    {"total_count":1,"installations":[{"id":10,"account":{"id":100,"login":"snow","type":"Organization","avatar_url":null},"repository_selection":"all","permissions":\(permissions),"suspended_at":null}]}
    """
    let repositories = """
    {"total_count":1,"repositories":[{"id":1,"name":"app","full_name":"snow/app","private":\(repositoryIsPrivate),"owner":{"id":100,"login":"snow","type":"Organization","avatar_url":null},"permissions":{"admin":false,"maintain":false,"push":false,"triage":false,"pull":true}}]}
    """
    return [
        DetailHTTPResponse(user),
        DetailHTTPResponse(user),
        DetailHTTPResponse(installation),
        DetailHTTPResponse(repositories),
    ]
}

private func detailActivityItem() -> ActivityItem {
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

private func correlatedDetailEvidence() throws -> GitHubDeliveryTimelineEvidence {
    GitHubDeliveryTimelineEvidence(
        selectedRun: detailRun(
            id: 700,
            branch: "feature/timeline",
            headSHA: "final-head",
            pullRequestNumbers: [47]
        ),
        pullRequest: GitHubPullRequestMetadata(
            number: 47,
            state: .closed,
            isDraft: false,
            isMerged: true,
            headRef: "feature/timeline",
            headSHA: "final-head",
            baseRef: "main",
            baseSHA: "before-merge",
            mergeCommitSHA: nil,
            webURL: try #require(URL(string: "https://github.com/snow/app/pull/47")),
            updatedAt: Date(timeIntervalSince1970: 150),
            mergedAt: Date(timeIntervalSince1970: 149)
        ),
        baseRuns: [
            detailRun(id: 801, branch: "main", headSHA: "landed-sha"),
        ],
        associatedPullRequestNumbersByRunID: [801: [47]]
    )
}

private func detailDeploymentEvidence() -> GitHubDeploymentTimelineEvidence {
    GitHubDeploymentTimelineEvidence(
        exactSHA: "landed-sha",
        deployments: [
            GitHubDeploymentEvidence(
                deployment: GitHubDeployment(
                    id: 901,
                    sha: "landed-sha",
                    environment: "production",
                    isProductionEnvironment: true,
                    isTransientEnvironment: false,
                    createdAt: Date(timeIntervalSince1970: 130),
                    updatedAt: Date(timeIntervalSince1970: 140)
                ),
                latestStatus: GitHubDeploymentStatus(
                    id: 1_001,
                    state: .success,
                    environment: "production",
                    description: "Deployed",
                    environmentURL: URL(string: "https://deploy.example.test/production"),
                    logURL: URL(string: "https://deploy.example.test/logs/1001"),
                    createdAt: Date(timeIntervalSince1970: 141),
                    updatedAt: Date(timeIntervalSince1970: 142)
                )
            ),
        ]
    )
}

private func detailRun(
    id: Int64,
    workflowID: Int64 = 88,
    branch: String?,
    headSHA: String,
    pullRequestNumbers: [Int] = []
) -> GitHubWorkflowRun {
    GitHubWorkflowRun(
        id: id,
        workflowID: workflowID,
        name: "CI",
        displayTitle: "CI",
        event: pullRequestNumbers.isEmpty ? "push" : "pull_request",
        status: .completed,
        conclusion: .success,
        runNumber: Int(id),
        headBranch: branch,
        headSHA: headSHA,
        webURL: URL(string: "https://github.com/snow/app/actions/runs/\(id)")!,
        pullRequestNumbers: pullRequestNumbers,
        createdAt: Date(timeIntervalSince1970: 100),
        updatedAt: Date(timeIntervalSince1970: 120)
    )
}

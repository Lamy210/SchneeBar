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

private actor DetailMutationRecorder: GitHubWorkflowRunMutating {
    private var rerunIDs: [Int64] = []
    private var cancelIDs: [Int64] = []

    func rerun(
        connection: GitHubConnection,
        identity: GitHubAccountIdentity,
        clientID: String?,
        repository: GitHubRepositoryAccess,
        runID: Int64
    ) async throws {
        rerunIDs.append(runID)
    }

    func cancel(
        connection: GitHubConnection,
        identity: GitHubAccountIdentity,
        clientID: String?,
        repository: GitHubRepositoryAccess,
        runID: Int64
    ) async throws {
        cancelIDs.append(runID)
    }

    func reruns() -> [Int64] {
        rerunIDs
    }

    func cancellations() -> [Int64] {
        cancelIDs
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
    private var repositories: [GitHubRepositoryAccess] = []

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
        repositories.append(repository)
        switch outcome {
        case let .evidence(evidence):
            return evidence
        case .failure:
            throw DetailTimelineError.failed
        }
    }

    func calls() -> Int { callCount }
    func requestedRepositories() -> [GitHubRepositoryAccess] { repositories }
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

private enum DetailEnvironmentOutcome: Sendable {
    case catalog(GitHubEnvironmentCatalog)
    case failure
    case cancellation
}

private actor DetailEnvironmentCatalogLoader: GitHubEnvironmentCatalogLoading {
    private let outcome: DetailEnvironmentOutcome
    private var requestCount = 0

    init(_ outcome: DetailEnvironmentOutcome) {
        self.outcome = outcome
    }

    func environmentCatalog(
        connection: GitHubConnection,
        identity: GitHubAccountIdentity,
        clientID: String?,
        repository: GitHubRepositoryAccess
    ) async throws -> GitHubEnvironmentCatalog {
        requestCount += 1
        switch outcome {
        case let .catalog(catalog):
            return catalog
        case .failure:
            throw DetailTimelineError.failed
        case .cancellation:
            throw CancellationError()
        }
    }

    func calls() -> Int { requestCount }
}

private enum DetailActionsCapabilityFixture {
    case available
    case unavailable
    case unknown
}

private func emptyEnvironmentCatalogLoader() -> DetailEnvironmentCatalogLoader {
    DetailEnvironmentCatalogLoader(
        .catalog(
            GitHubEnvironmentCatalog(
                totalCount: 0,
                environments: [],
                isTruncated: false
            )
        )
    )
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
        environmentCatalogLoader: emptyEnvironmentCatalogLoader(),
        timelineBuilder: GitHubDeliveryTimelineBuilder()
    )

    #expect(detail.rows.map(\.id) == ["7001"])
    #expect(detail.deliveryTimeline?.status == .correlated)
    #expect(detail.deliveryTimeline?.confidence == .exact)
    #expect(detail.deliveryTimeline?.events.map(\.kind) == [.pullRequest, .merge, .execution])
    #expect(await timelineLoader.calls() == 1)
    let requestedRepository = try #require(await timelineLoader.requestedRepositories().first)
    #expect(requestedRepository.fullName == "snow/app")
    #expect(requestedRepository.defaultBranch == "main")
    #expect(await deploymentLoader.SHAs() == ["landed-sha"])
}

@Test @MainActor
func activityDetailActionsUseActivitySnapshotStateAndConfirmedWriteCapability() async throws {
    let fixture = try await detailFixture(
        jobStatusCode: 200,
        workflowWriteAvailable: true
    )
    let timelineLoader = DetailTimelineLoader(
        .evidence(try correlatedDetailEvidence())
    )
    let deploymentLoader = DetailDeploymentLoader(
        .evidence(
            GitHubDeploymentTimelineEvidence(
                exactSHA: "landed-sha",
                deployments: []
            )
        )
    )

    let detail = try await fixture.model.loadActivityDetail(
        for: detailActivityItem(state: .running),
        jobService: fixture.jobService,
        timelineLoader: timelineLoader,
        deploymentTimelineLoader: deploymentLoader,
        environmentCatalogLoader: emptyEnvironmentCatalogLoader(),
        timelineBuilder: GitHubDeliveryTimelineBuilder()
    )

    #expect(detail.state == .running)
    #expect(detail.actions == [.cancelWorkflow])
}

@Test @MainActor
func workflowMutationExecutesOnlyWithConfirmedWriteCapability() async throws {
    let fixture = try await detailFixture(
        jobStatusCode: 200,
        workflowWriteAvailable: true
    )
    let recorder = DetailMutationRecorder()
    var refreshCount = 0
    fixture.model.onActivitySourceChanged = {
        refreshCount += 1
    }

    try await fixture.model.performWorkflowRunAction(
        .rerunWorkflow,
        for: detailActivityItem(state: .failed),
        mutationService: recorder
    )

    #expect(await recorder.reruns() == [700])
    #expect(await recorder.cancellations().isEmpty)
    #expect(refreshCount == 1)
}

private struct DetailRejectedMutationService: GitHubWorkflowRunMutating {
    func rerun(
        connection: GitHubConnection,
        identity: GitHubAccountIdentity,
        clientID: String?,
        repository: GitHubRepositoryAccess,
        runID: Int64
    ) async throws {
        throw GitHubConnectionSessionError.reauthenticationRequired
    }

    func cancel(
        connection: GitHubConnection,
        identity: GitHubAccountIdentity,
        clientID: String?,
        repository: GitHubRepositoryAccess,
        runID: Int64
    ) async throws {
        throw GitHubConnectionSessionError.reauthenticationRequired
    }
}

@Test @MainActor
func workflowMutationAuthenticationFailureUpdatesConnectionHealth() async throws {
    let fixture = try await detailFixture(
        jobStatusCode: 200,
        workflowWriteAvailable: true
    )
    var refreshCount = 0
    fixture.model.onActivitySourceChanged = {
        refreshCount += 1
    }

    await #expect(
        throws: GitHubConnectionSessionError.reauthenticationRequired
    ) {
        try await fixture.model.performWorkflowRunAction(
            .rerunWorkflow,
            for: detailActivityItem(state: .failed),
            mutationService: DetailRejectedMutationService()
        )
    }

    #expect(
        fixture.model.connectionCards.first?.status
            == .authenticationRequired
    )
    #expect(refreshCount == 1)
}

private struct DetailMissingCredentialMutationService: GitHubWorkflowRunMutating {
    func rerun(
        connection: GitHubConnection,
        identity: GitHubAccountIdentity,
        clientID: String?,
        repository: GitHubRepositoryAccess,
        runID: Int64
    ) async throws {
        throw GitHubConnectionSessionError.credentialNotFound
    }

    func cancel(
        connection: GitHubConnection,
        identity: GitHubAccountIdentity,
        clientID: String?,
        repository: GitHubRepositoryAccess,
        runID: Int64
    ) async throws {
        throw GitHubConnectionSessionError.credentialNotFound
    }
}

@Test @MainActor
func workflowMutationMissingCredentialUpdatesConnectionHealth() async throws {
    let fixture = try await detailFixture(
        jobStatusCode: 200,
        workflowWriteAvailable: true
    )
    var refreshCount = 0
    fixture.model.onActivitySourceChanged = {
        refreshCount += 1
    }

    await #expect(throws: GitHubConnectionSessionError.credentialNotFound) {
        try await fixture.model.performWorkflowRunAction(
            .rerunWorkflow,
            for: detailActivityItem(state: .failed),
            mutationService: DetailMissingCredentialMutationService()
        )
    }

    #expect(
        fixture.model.connectionCards.first?.status
            == .authenticationRequired
    )
    #expect(refreshCount == 1)
}

private struct DetailSSORequiredMutationService: GitHubWorkflowRunMutating {
    func rerun(
        connection: GitHubConnection,
        identity: GitHubAccountIdentity,
        clientID: String?,
        repository: GitHubRepositoryAccess,
        runID: Int64
    ) async throws {
        throw GitHubConnectionSessionError.ssoRequired
    }

    func cancel(
        connection: GitHubConnection,
        identity: GitHubAccountIdentity,
        clientID: String?,
        repository: GitHubRepositoryAccess,
        runID: Int64
    ) async throws {
        throw GitHubConnectionSessionError.ssoRequired
    }
}

@Test @MainActor
func workflowMutationSSOFailureUpdatesConnectionHealth() async throws {
    let fixture = try await detailFixture(
        jobStatusCode: 200,
        workflowWriteAvailable: true
    )
    var refreshCount = 0
    fixture.model.onActivitySourceChanged = {
        refreshCount += 1
    }

    await #expect(throws: GitHubConnectionSessionError.ssoRequired) {
        try await fixture.model.performWorkflowRunAction(
            .rerunWorkflow,
            for: detailActivityItem(state: .failed),
            mutationService: DetailSSORequiredMutationService()
        )
    }

    #expect(
        fixture.model.connectionCards.first?.status
            == .ssoRequired
    )
    #expect(refreshCount == 1)
}

@Test @MainActor
func workflowMutationCannotBypassUnavailableWriteCapability() async throws {
    let fixture = try await detailFixture(jobStatusCode: 200)
    let recorder = DetailMutationRecorder()

    await #expect(throws: WorkflowRunActionError.unavailable) {
        try await fixture.model.performWorkflowRunAction(
            .rerunWorkflow,
            for: detailActivityItem(state: .failed),
            mutationService: recorder
        )
    }

    #expect(await recorder.reruns().isEmpty)
    #expect(await recorder.cancellations().isEmpty)
}

@Test @MainActor
func workflowMutationCannotBypassRunStateActionGate() async throws {
    let fixture = try await detailFixture(
        jobStatusCode: 200,
        workflowWriteAvailable: true
    )
    let recorder = DetailMutationRecorder()

    await #expect(throws: WorkflowRunActionError.unavailable) {
        try await fixture.model.performWorkflowRunAction(
            .cancelWorkflow,
            for: detailActivityItem(state: .failed),
            mutationService: recorder
        )
    }

    await #expect(throws: WorkflowRunActionError.unavailable) {
        try await fixture.model.performWorkflowRunAction(
            .rerunWorkflow,
            for: detailActivityItem(state: .running),
            mutationService: recorder
        )
    }

    #expect(await recorder.reruns().isEmpty)
    #expect(await recorder.cancellations().isEmpty)
}

@Test @MainActor
func activityDetailRejectsDestinationRepositoryMismatch() async throws {
    let fixture = try await detailFixture(
        jobStatusCode: 200,
        workflowWriteAvailable: true
    )
    let timelineLoader = DetailTimelineLoader(
        .evidence(try correlatedDetailEvidence())
    )
    let deploymentLoader = DetailDeploymentLoader(
        .evidence(
            GitHubDeploymentTimelineEvidence(
                exactSHA: "unused",
                deployments: []
            )
        )
    )

    await #expect(throws: ActivityDetailLoadingError.unsupportedActivity) {
        _ = try await fixture.model.loadActivityDetail(
            for: detailActivityItem(
                destinationURL: URL(
                    string: "https://github.com/other/repo/actions/runs/700"
                )
            ),
            jobService: fixture.jobService,
            timelineLoader: timelineLoader,
            deploymentTimelineLoader: deploymentLoader,
            environmentCatalogLoader: emptyEnvironmentCatalogLoader(),
            timelineBuilder: GitHubDeliveryTimelineBuilder()
        )
    }

    #expect(await timelineLoader.calls() == 0)
    #expect(await deploymentLoader.calls() == 0)
}

@Test @MainActor
func activityDetailRejectsNonHTTPSWorkflowDestination() async throws {
    let fixture = try await detailFixture(
        jobStatusCode: 200,
        workflowWriteAvailable: true
    )
    let recorder = DetailMutationRecorder()

    await #expect(throws: ActivityDetailLoadingError.activityContextUnavailable) {
        try await fixture.model.performWorkflowRunAction(
            .rerunWorkflow,
            for: detailActivityItem(
                state: .failed,
                destinationURL: URL(
                    string: "http://github.com/snow/app/actions/runs/700"
                )
            ),
            mutationService: recorder
        )
    }

    #expect(await recorder.reruns().isEmpty)
}

@Test @MainActor
func activityDetailRejectsAmbiguousRuntimeRepositoryMatch() async throws {
    let fixture = try await detailFixture(
        jobStatusCode: 200,
        duplicateRepositoryFullName: true
    )
    let timelineLoader = DetailTimelineLoader(.evidence(try correlatedDetailEvidence()))
    let deploymentLoader = DetailDeploymentLoader(
        .evidence(GitHubDeploymentTimelineEvidence(exactSHA: "unused", deployments: []))
    )

    await #expect(throws: (any Error).self) {
        _ = try await fixture.model.loadActivityDetail(
            for: detailActivityItem(),
            jobService: fixture.jobService,
            timelineLoader: timelineLoader,
            deploymentTimelineLoader: deploymentLoader,
            environmentCatalogLoader: emptyEnvironmentCatalogLoader(),
            timelineBuilder: GitHubDeliveryTimelineBuilder()
        )
    }

    #expect(await timelineLoader.calls() == 0)
    #expect(await deploymentLoader.calls() == 0)
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
        environmentCatalogLoader: emptyEnvironmentCatalogLoader(),
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
        environmentCatalogLoader: emptyEnvironmentCatalogLoader(),
        timelineBuilder: GitHubDeliveryTimelineBuilder()
    )

    #expect(detail.rows.map(\.id) == ["7001"])
    #expect(detail.deliveryTimeline?.status == .temporarilyUnavailable)
    #expect(detail.deliveryTimeline?.confidence == .unknown)
    #expect(detail.deliveryTimeline?.events.isEmpty == true)
    #expect(detail.deliveryTimeline?.evidence == [
        DeliveryTimelineEvidenceItem(
            id: "delivery-evidence-load",
            title: "Delivery evidence",
            detail: "GitHub evidence could not be loaded right now",
            state: .unavailable
        ),
    ])
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
            environmentCatalogLoader: emptyEnvironmentCatalogLoader(),
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
        environmentCatalogLoader: emptyEnvironmentCatalogLoader(),
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
        environmentCatalogLoader: emptyEnvironmentCatalogLoader(),
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
        environmentCatalogLoader: emptyEnvironmentCatalogLoader(),
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
        environmentCatalogLoader: emptyEnvironmentCatalogLoader(),
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
            environmentCatalogLoader: emptyEnvironmentCatalogLoader(),
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
    deploymentCapability: DetailDeploymentCapabilityFixture = .available,
    actionsCapability: DetailActionsCapabilityFixture = .available,
    workflowWriteAvailable: Bool = false,
    duplicateRepositoryFullName: Bool = false
) async throws -> DetailFixture {
    let profile = try detailProfile()
    let profileStore = DetailProfileStore([profile])
    let credentialStore = DetailCredentialStore(profile: profile)
    let accessTransport = DetailQueueTransport(
        detailSessionResponses(
            deploymentCapability: deploymentCapability,
            actionsCapability: actionsCapability,
            workflowWriteAvailable: workflowWriteAvailable,
            duplicateRepositoryFullName: duplicateRepositoryFullName
        )
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
    deploymentCapability: DetailDeploymentCapabilityFixture,
    actionsCapability: DetailActionsCapabilityFixture,
    workflowWriteAvailable: Bool,
    duplicateRepositoryFullName: Bool
) -> [DetailHTTPResponse] {
    let user = #"{"id":42,"login":"snow-user","name":"Snow User","avatar_url":null}"#

    var permissionPairs = ["\"pull_requests\":\"read\""]
    if workflowWriteAvailable {
        permissionPairs.append("\"actions\":\"write\"")
    } else {
        switch actionsCapability {
        case .available:
            permissionPairs.append("\"actions\":\"read\"")
        case .unavailable, .unknown:
            break
        }
    }
    switch deploymentCapability {
    case .available:
        permissionPairs.append("\"deployments\":\"read\"")
    case .unavailable, .unknown:
        break
    }
    let permissions = "{\(permissionPairs.joined(separator: ","))}"

    let repositoryIsPrivate = !(
        actionsCapability == .unknown
            || deploymentCapability == .unknown
    )

    let installation = """
    {"total_count":1,"installations":[{"id":10,"account":{"id":100,"login":"snow","type":"Organization","avatar_url":null},"repository_selection":"all","permissions":\(permissions),"suspended_at":null}]}
    """
    let duplicateRepository = duplicateRepositoryFullName
        ? """
        ,{"id":2,"name":"app-shadow","full_name":"snow/app","private":\(repositoryIsPrivate),"owner":{"id":100,"login":"snow","type":"Organization","avatar_url":null},"permissions":{"admin":false,"maintain":false,"push":\(workflowWriteAvailable),"triage":false,"pull":true},"default_branch":"main"}
        """
        : ""
    let repositoryCount = duplicateRepositoryFullName ? 2 : 1
    let repositories = """
    {"total_count":\(repositoryCount),"repositories":[{"id":1,"name":"app","full_name":"snow/app","private":\(repositoryIsPrivate),"owner":{"id":100,"login":"snow","type":"Organization","avatar_url":null},"permissions":{"admin":false,"maintain":false,"push":\(workflowWriteAvailable),"triage":false,"pull":true},"default_branch":"main"}\(duplicateRepository)]}
    """
    return [
        DetailHTTPResponse(user),
        DetailHTTPResponse(user),
        DetailHTTPResponse(installation),
        DetailHTTPResponse(repositories),
    ]
}

private func detailActivityItem(
    state: ActivityState = .success,
    destinationURL: URL? = URL(
        string: "https://github.com/snow/app/actions/runs/700"
    )
) -> ActivityItem {
    ActivityItem(
        id: "github-actions:1:700",
        repository: "snow/app",
        context: "PR #47 · CI",
        detail: "Succeeded",
        state: state,
        destinationURL: destinationURL,
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


@Test @MainActor
func activityDetailEnrichesDeploymentWithEnvironmentCatalog() async throws {
    let fixture = try await detailFixture(jobStatusCode: 200)
    let timelineLoader = DetailTimelineLoader(.evidence(try correlatedDetailEvidence()))
    let deploymentLoader = DetailDeploymentLoader(.evidence(detailDeploymentEvidence()))
    let environmentLoader = DetailEnvironmentCatalogLoader(
        .catalog(
            GitHubEnvironmentCatalog(
                totalCount: 1,
                environments: [
                    GitHubEnvironment(
                        id: 301,
                        name: "production",
                        protection: GitHubEnvironmentProtection(
                            waitTimerMinutes: 30,
                            requiredReviewerCount: 2,
                            preventsSelfReview: false,
                            branchPolicy: .customBranches
                        ),
                        createdAt: nil,
                        updatedAt: nil
                    ),
                ],
                isTruncated: false
            )
        )
    )

    let detail = try await fixture.model.loadActivityDetail(
        for: detailActivityItem(),
        jobService: fixture.jobService,
        timelineLoader: timelineLoader,
        deploymentTimelineLoader: deploymentLoader,
        environmentCatalogLoader: environmentLoader,
        timelineBuilder: GitHubDeliveryTimelineBuilder()
    )

    #expect(await environmentLoader.calls() == 1)
    #expect(
        detail.deliveryTimeline?.events.last?.detail
            == "Succeeded · Production · 2 reviewers · 30m wait · Custom branches"
    )
}

@Test @MainActor
func activityDetailSkipsEnvironmentWhenDeploymentEvidenceIsEmpty() async throws {
    let fixture = try await detailFixture(jobStatusCode: 200)
    let timelineLoader = DetailTimelineLoader(.evidence(try correlatedDetailEvidence()))
    let deploymentLoader = DetailDeploymentLoader(
        .evidence(
            GitHubDeploymentTimelineEvidence(
                exactSHA: "landed-sha",
                deployments: []
            )
        )
    )
    let environmentLoader = emptyEnvironmentCatalogLoader()

    _ = try await fixture.model.loadActivityDetail(
        for: detailActivityItem(),
        jobService: fixture.jobService,
        timelineLoader: timelineLoader,
        deploymentTimelineLoader: deploymentLoader,
        environmentCatalogLoader: environmentLoader,
        timelineBuilder: GitHubDeliveryTimelineBuilder()
    )

    #expect(await deploymentLoader.calls() == 1)
    #expect(await environmentLoader.calls() == 0)
}

@Test @MainActor
func activityDetailSkipsEnvironmentWhenActionsCapabilityIsUnavailable() async throws {
    let fixture = try await detailFixture(
        jobStatusCode: 200,
        deploymentCapability: .available,
        actionsCapability: .unavailable
    )
    let timelineLoader = DetailTimelineLoader(.evidence(try correlatedDetailEvidence()))
    let deploymentLoader = DetailDeploymentLoader(.evidence(detailDeploymentEvidence()))
    let environmentLoader = emptyEnvironmentCatalogLoader()

    let detail = try await fixture.model.loadActivityDetail(
        for: detailActivityItem(),
        jobService: fixture.jobService,
        timelineLoader: timelineLoader,
        deploymentTimelineLoader: deploymentLoader,
        environmentCatalogLoader: environmentLoader,
        timelineBuilder: GitHubDeliveryTimelineBuilder()
    )

    #expect(await deploymentLoader.calls() == 1)
    #expect(await environmentLoader.calls() == 0)
    #expect(detail.deliveryTimeline?.events.last?.detail == "Succeeded · Production")
}

@Test @MainActor
func activityDetailAllowsEnvironmentRequestWhenActionsCapabilityIsUnknown() async throws {
    let fixture = try await detailFixture(
        jobStatusCode: 200,
        deploymentCapability: .available,
        actionsCapability: .unknown
    )
    let timelineLoader = DetailTimelineLoader(.evidence(try correlatedDetailEvidence()))
    let deploymentLoader = DetailDeploymentLoader(.evidence(detailDeploymentEvidence()))
    let environmentLoader = emptyEnvironmentCatalogLoader()

    _ = try await fixture.model.loadActivityDetail(
        for: detailActivityItem(),
        jobService: fixture.jobService,
        timelineLoader: timelineLoader,
        deploymentTimelineLoader: deploymentLoader,
        environmentCatalogLoader: environmentLoader,
        timelineBuilder: GitHubDeliveryTimelineBuilder()
    )

    #expect(await environmentLoader.calls() == 1)
}

@Test @MainActor
func activityDetailPreservesDeploymentWhenEnvironmentLoadingFails() async throws {
    let fixture = try await detailFixture(jobStatusCode: 200)
    let timelineLoader = DetailTimelineLoader(.evidence(try correlatedDetailEvidence()))
    let deploymentLoader = DetailDeploymentLoader(.evidence(detailDeploymentEvidence()))
    let environmentLoader = DetailEnvironmentCatalogLoader(.failure)

    let detail = try await fixture.model.loadActivityDetail(
        for: detailActivityItem(),
        jobService: fixture.jobService,
        timelineLoader: timelineLoader,
        deploymentTimelineLoader: deploymentLoader,
        environmentCatalogLoader: environmentLoader,
        timelineBuilder: GitHubDeliveryTimelineBuilder()
    )

    #expect(await environmentLoader.calls() == 1)
    #expect(detail.rows.map(\.id) == ["7001"])
    #expect(detail.deliveryTimeline?.status == .correlated)
    #expect(detail.deliveryTimeline?.events.last?.kind == .deployment)
    #expect(detail.deliveryTimeline?.events.last?.detail == "Succeeded · Production")
}

@Test @MainActor
func activityDetailPropagatesEnvironmentCancellation() async throws {
    let fixture = try await detailFixture(jobStatusCode: 200)
    let timelineLoader = DetailTimelineLoader(.evidence(try correlatedDetailEvidence()))
    let deploymentLoader = DetailDeploymentLoader(.evidence(detailDeploymentEvidence()))
    let environmentLoader = DetailEnvironmentCatalogLoader(.cancellation)

    await #expect(throws: CancellationError.self) {
        _ = try await fixture.model.loadActivityDetail(
            for: detailActivityItem(),
            jobService: fixture.jobService,
            timelineLoader: timelineLoader,
            deploymentTimelineLoader: deploymentLoader,
            environmentCatalogLoader: environmentLoader,
            timelineBuilder: GitHubDeliveryTimelineBuilder()
        )
    }

    #expect(await environmentLoader.calls() == 1)
}

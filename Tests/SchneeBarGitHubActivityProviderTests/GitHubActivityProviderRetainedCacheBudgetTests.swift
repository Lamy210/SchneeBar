import Foundation
import SchneeBarCore
import SchneeBarGitHub
import SchneeBarGitHubActivityProvider
import Testing

private enum RetainedCacheLoaderMode: Sendable {
    case success
    case failure
    case delayedFailure
}

private actor RetainedCacheWorkflowLoader:
    GitHubWorkflowRunLoading
{
    private var mode: RetainedCacheLoaderMode = .success
    private var calls: [Int64] = []
    private let runsPerRepository: Int

    init(runsPerRepository: Int = 1) {
        self.runsPerRepository = runsPerRepository
    }

    func setMode(_ mode: RetainedCacheLoaderMode) {
        self.mode = mode
    }

    func recordedCalls() -> [Int64] {
        calls
    }

    func callCount() -> Int {
        calls.count
    }

    func workflowRuns(
        connection: GitHubConnection,
        identity: GitHubAccountIdentity,
        clientID: String?,
        repository: GitHubRepositoryAccess,
        query: GitHubWorkflowRunQuery
    ) async throws -> [GitHubWorkflowRun] {
        calls.append(repository.id)

        switch mode {
        case .success:
            return try (0 ..< min(runsPerRepository, query.limit)).map {
                index in
                let runID = repository.id * 1_000 + Int64(index + 1)
                return GitHubWorkflowRun(
                    id: runID,
                    workflowID: Int64(index + 1),
                    name: "CI",
                    displayTitle: "Build \(index + 1)",
                    event: "push",
                    status: .completed,
                    conclusion: .failure,
                    runNumber: index + 1,
                    headBranch: "main",
                    headSHA: String(format: "%040llx", runID),
                    webURL: repository.webURL.appendingPathComponent(
                        "actions/runs/\(runID)"
                    ),
                    pullRequestNumbers: [],
                    createdAt: Date(
                        timeIntervalSince1970: 90 + Double(index)
                    ),
                    updatedAt: Date(
                        timeIntervalSince1970: 100 + Double(index)
                    )
                )
            }

        case .failure:
            throw GitHubActionsClientError.httpStatus(503)

        case .delayedFailure:
            try await Task.sleep(nanoseconds: 250_000_000)
            throw GitHubActionsClientError.httpStatus(503)
        }
    }
}

private actor RetainedCacheReviewLoader:
    GitHubReviewRequestLoading
{
    private var mode: RetainedCacheLoaderMode = .success

    func setMode(_ mode: RetainedCacheLoaderMode) {
        self.mode = mode
    }

    func reviewRequests(
        connection: GitHubConnection,
        identity: GitHubAccountIdentity,
        clientID: String?,
        repository: GitHubRepositoryAccess
    ) async throws -> [GitHubReviewRequest] {
        switch mode {
        case .success:
            return [
                GitHubReviewRequest(
                    number: Int(repository.id),
                    title: "Review \(repository.id)",
                    headSHA: String(
                        format: "%040llx",
                        repository.id
                    ),
                    isDraft: false,
                    updatedAt: Date(timeIntervalSince1970: 100),
                    requestedReviewerIDs: [identity.id],
                    webURL: repository.webURL.appendingPathComponent(
                        "pull/\(repository.id)"
                    )
                ),
            ]

        case .failure, .delayedFailure:
            throw GitHubPullRequestListClientError.httpStatus(503)
        }
    }
}

private actor RetainedCacheCheckLoader:
    GitHubCheckRunLoading
{
    private var mode: RetainedCacheLoaderMode = .success

    func setMode(_ mode: RetainedCacheLoaderMode) {
        self.mode = mode
    }

    func checkRuns(
        connection: GitHubConnection,
        identity: GitHubAccountIdentity,
        clientID: String?,
        repository: GitHubRepositoryAccess,
        headSHA: String
    ) async throws -> [GitHubCheckRun] {
        switch mode {
        case .success:
            return [
                GitHubCheckRun(
                    id: repository.id * 100,
                    name: "External CI",
                    status: .completed,
                    conclusion: .failure,
                    appSlug: "external-ci",
                    headSHA: headSHA,
                    startedAt: Date(timeIntervalSince1970: 90),
                    completedAt: Date(timeIntervalSince1970: 100),
                    webURL: repository.webURL.appendingPathComponent(
                        "commit/\(headSHA)/checks"
                    )
                ),
            ]

        case .failure, .delayedFailure:
            throw GitHubCheckRunClientError.httpStatus(503)
        }
    }
}

@Test
func retainedWorkflowAndReviewBudgetsEvictDeterministically() async throws {
    let repositories = try retainedCacheRepositories(count: 3)
    let workflows = RetainedCacheWorkflowLoader()
    let reviews = RetainedCacheReviewLoader()
    let provider = GitHubActivityProvider(
        workflowRunLoader: workflows,
        reviewRequestLoader: reviews,
        maximumConcurrentRepositories: 3,
        maximumRepositoriesPerRefresh: 3,
        maximumReviewRepositoriesPerRefresh: 3,
        minimumColdRepositoriesPerRefresh: 3,
        minimumColdReviewRepositoriesPerRefresh: 3,
        cachePolicy: GitHubActivityCachePolicy(
            maximumWorkflowRepositories: 2,
            maximumReviewRepositories: 2,
            maximumCheckTargets: 2,
            maximumRecoveryLanesPerRepository: 2,
            maximumRetainedItemsPerSurface: 10,
            maximumRetainedFailuresPerSurface: 10
        ),
        now: { Date(timeIntervalSince1970: 100) }
    )
    let profile = try retainedCacheProfile()
    let inventory = try retainedCacheInventory(
        repositories: repositories
    )
    let capabilities = retainedCacheCapabilities(
        repositories: repositories
    )

    let first = await provider.load(
        profile: profile,
        inventory: inventory,
        capabilities: capabilities
    )
    #expect(first.surface(.workflows).items.count == 3)
    #expect(first.surface(.reviewRequests).items.count == 3)

    await workflows.setMode(.failure)
    await reviews.setMode(.failure)

    let failedRefresh = await provider.load(
        profile: profile,
        inventory: inventory,
        capabilities: capabilities
    )

    #expect(
        failedRefresh.surface(.workflows).items.map(\.repository)
            == ["snow/repo-01", "snow/repo-02"]
    )
    #expect(
        failedRefresh.surface(.reviewRequests).items.map(\.repository)
            == ["snow/repo-01", "snow/repo-02"]
    )
    #expect(failedRefresh.surface(.workflows).failures.count == 3)
    #expect(failedRefresh.surface(.reviewRequests).failures.count == 3)

    await provider.reset(connectionID: profile.id)

    let afterReset = await provider.load(
        profile: profile,
        inventory: inventory,
        capabilities: capabilities
    )
    #expect(afterReset.surface(.workflows).items.isEmpty)
    #expect(afterReset.surface(.reviewRequests).items.isEmpty)
}

@Test
func retainedCheckBudgetEvictsLeastPreferredTarget() async throws {
    let repositories = try retainedCacheRepositories(count: 3)
    let workflows = RetainedCacheWorkflowLoader(
        runsPerRepository: 0
    )
    let reviews = RetainedCacheReviewLoader()
    let checks = RetainedCacheCheckLoader()
    let provider = GitHubActivityProvider(
        workflowRunLoader: workflows,
        reviewRequestLoader: reviews,
        checkRunLoader: checks,
        maximumConcurrentRepositories: 3,
        maximumRepositoriesPerRefresh: 3,
        maximumReviewRepositoriesPerRefresh: 3,
        maximumCheckTargetsPerRefresh: 3,
        maximumCheckTargetsPerRepository: 1,
        minimumColdRepositoriesPerRefresh: 3,
        minimumColdReviewRepositoriesPerRefresh: 3,
        cachePolicy: GitHubActivityCachePolicy(
            maximumWorkflowRepositories: 3,
            maximumReviewRepositories: 3,
            maximumCheckTargets: 2,
            maximumRecoveryLanesPerRepository: 2,
            maximumRetainedItemsPerSurface: 10,
            maximumRetainedFailuresPerSurface: 10
        ),
        now: { Date(timeIntervalSince1970: 100) }
    )
    let profile = try retainedCacheProfile()
    let inventory = try retainedCacheInventory(
        repositories: repositories
    )
    let capabilities = retainedCacheCapabilities(
        repositories: repositories
    )

    let first = await provider.load(
        profile: profile,
        inventory: inventory,
        capabilities: capabilities
    )
    #expect(first.surface(.checks).items.count == 3)

    await checks.setMode(.failure)
    let second = await provider.load(
        profile: profile,
        inventory: inventory,
        capabilities: capabilities
    )

    #expect(second.surface(.checks).items.count == 2)
    #expect(
        second.surface(.checks).items.map(\.repository)
            == ["snow/repo-01", "snow/repo-02"]
    )
}

@Test
func cacheEvictionPreservesColdRepositoryPollingFairness() async throws {
    let repositories = try retainedCacheRepositories(count: 4)
    let workflows = RetainedCacheWorkflowLoader()
    let reviews = RetainedCacheReviewLoader()
    let provider = GitHubActivityProvider(
        workflowRunLoader: workflows,
        reviewRequestLoader: reviews,
        maximumConcurrentRepositories: 1,
        maximumRepositoriesPerRefresh: 1,
        maximumReviewRepositoriesPerRefresh: 1,
        minimumColdRepositoriesPerRefresh: 1,
        minimumColdReviewRepositoriesPerRefresh: 1,
        cachePolicy: GitHubActivityCachePolicy(
            maximumWorkflowRepositories: 1,
            maximumReviewRepositories: 1,
            maximumCheckTargets: 1,
            maximumRecoveryLanesPerRepository: 1,
            maximumRetainedItemsPerSurface: 10,
            maximumRetainedFailuresPerSurface: 10
        ),
        now: { Date(timeIntervalSince1970: 100) }
    )
    let profile = try retainedCacheProfile()
    let inventory = try retainedCacheInventory(
        repositories: repositories
    )
    let capabilities = retainedCacheCapabilities(
        repositories: repositories
    )

    for _ in 0 ..< 4 {
        _ = await provider.load(
            profile: profile,
            inventory: inventory,
            capabilities: capabilities
        )
    }

    #expect(await workflows.recordedCalls() == [1, 2, 3, 4])
}

@Test
func retainedCachePrefersLatestAttemptBatchWhenClockDoesNotAdvance() async throws {
    let repositories = try retainedCacheRepositories(count: 2)
    let workflows = RetainedCacheWorkflowLoader()
    let provider = GitHubActivityProvider(
        workflowRunLoader: workflows,
        maximumConcurrentRepositories: 1,
        maximumRepositoriesPerRefresh: 1,
        minimumColdRepositoriesPerRefresh: 1,
        cachePolicy: GitHubActivityCachePolicy(
            maximumWorkflowRepositories: 1,
            maximumReviewRepositories: 1,
            maximumCheckTargets: 1,
            maximumRecoveryLanesPerRepository: 1,
            maximumRetainedItemsPerSurface: 10,
            maximumRetainedFailuresPerSurface: 10
        ),
        now: { Date(timeIntervalSince1970: 100) }
    )
    let profile = try retainedCacheProfile()
    let inventory = try retainedCacheInventory(repositories: repositories)
    let capabilities = retainedCacheCapabilities(repositories: repositories)

    _ = await provider.load(
        profile: profile,
        inventory: inventory,
        capabilities: capabilities
    )
    _ = await provider.load(
        profile: profile,
        inventory: inventory,
        capabilities: capabilities
    )

    await workflows.setMode(.failure)
    await reviews.setMode(.failure)
    let failedRefresh = await provider.load(
        profile: profile,
        inventory: inventory,
        capabilities: capabilities
    )

    #expect(
        failedRefresh.surface(.workflows).items.map(\.repository)
            == ["snow/repo-02"]
    )
    #expect(
        failedRefresh.surface(.reviewRequests).items.map(\.repository)
            == ["snow/repo-02"]
    )
}

@Test
func concurrentLoadReturnsBoundedRetainedLastResult() async throws {
    let repository = try #require(
        retainedCacheRepositories(count: 1).first
    )
    let workflows = RetainedCacheWorkflowLoader(
        runsPerRepository: 5
    )
    let provider = GitHubActivityProvider(
        workflowRunLoader: workflows,
        maximumConcurrentRepositories: 1,
        perRepositoryRunLimit: 5,
        maximumRepositoriesPerRefresh: 1,
        minimumColdRepositoriesPerRefresh: 1,
        cachePolicy: GitHubActivityCachePolicy(
            maximumWorkflowRepositories: 1,
            maximumReviewRepositories: 1,
            maximumCheckTargets: 1,
            maximumRecoveryLanesPerRepository: 1,
            maximumRetainedItemsPerSurface: 2,
            maximumRetainedFailuresPerSurface: 1
        ),
        now: { Date(timeIntervalSince1970: 100) }
    )
    let profile = try retainedCacheProfile()
    let inventory = try retainedCacheInventory(
        repositories: [repository]
    )
    let capabilities = retainedCacheCapabilities(
        repositories: [repository]
    )

    let first = await provider.load(
        profile: profile,
        inventory: inventory,
        capabilities: capabilities
    )
    #expect(first.surface(.workflows).items.count == 5)

    await workflows.setMode(.delayedFailure)
    async let refreshing = provider.load(
        profile: profile,
        inventory: inventory,
        capabilities: capabilities
    )

    for _ in 0 ..< 100 {
        if await workflows.callCount() >= 2 {
            break
        }
        try await Task.sleep(nanoseconds: 2_000_000)
    }
    #expect(await workflows.callCount() >= 2)

    let retained = await provider.load(
        profile: profile,
        inventory: inventory,
        capabilities: capabilities
    )
    #expect(retained.surface(.workflows).items.count == 2)

    _ = await refreshing
}

@Test
func retainedLoadResultBoundsItemsAndFailuresButPreservesCounters() {
    let items = (1 ... 3).map { index in
        ActivityItem(
            id: "github-actions:1:\(index)",
            repository: "snow/repo",
            context: "CI",
            detail: "Build \(index)",
            state: .failed,
            updatedAt: Date(
                timeIntervalSince1970: Double(index)
            )
        )
    }
    let failures = (1 ... 3).map { index in
        GitHubActivityTargetFailure(
            surface: .workflows,
            repositoryID: Int64(index),
            repositoryFullName: "snow/repo-\(index)",
            reason: .unavailable
        )
    }
    let result = GitHubActivityLoadResult(
        surfaces: [
            .workflows: GitHubActivitySurfaceResult(
                surface: .workflows,
                items: items,
                failures: failures,
                successfulTargetCount: 7,
                attemptedTargetCount: 8,
                blockedTargetCount: 9
            ),
        ]
    )

    let retained = result.boundedForRetention(
        maximumItemsPerSurface: 2,
        maximumFailuresPerSurface: 1
    )
    let workflows = retained.surface(.workflows)

    #expect(workflows.items.count == 2)
    #expect(workflows.failures.count == 1)
    #expect(workflows.successfulTargetCount == 7)
    #expect(workflows.attemptedTargetCount == 8)
    #expect(workflows.blockedTargetCount == 9)
    #expect(retained.recoveryEvents.isEmpty)
}

private func retainedCacheProfile() throws -> GitHubConnectionProfile {
    GitHubConnectionProfile(
        connection: GitHubConnection(
            id: UUID(
                uuidString:
                    "66000000-0000-0000-0000-000000000001"
            )!,
            displayName: "GitHub.com",
            deploymentKind: .githubDotCom,
            webBaseURL: try #require(
                URL(string: "https://github.com")
            )
        ),
        account: GitHubAccountIdentity(
            id: "42",
            login: "snow-user"
        ),
        authenticationMethod: .deviceFlow,
        clientID: "Iv1.public-client-id",
        repositorySelection: .allAccessible,
        isEnabled: true
    )
}

private func retainedCacheRepositories(
    count: Int
) throws -> [GitHubRepositoryAccess] {
    try (1 ... count).map { index in
        let id = Int64(index)
        let fullName = String(
            format: "snow/repo-%02lld",
            id
        )
        return GitHubRepositoryAccess(
            id: id,
            name: String(
                format: "repo-%02lld",
                id
            ),
            fullName: fullName,
            isPrivate: false,
            webURL: try #require(
                URL(string: "https://github.com/\(fullName)")
            ),
            ownerLogin: "snow",
            permissions: GitHubRepositoryPermissions(
                pull: true
            )
        )
    }
}

private func retainedCacheInventory(
    repositories: [GitHubRepositoryAccess]
) throws -> GitHubAccessInventory {
    let profile = try retainedCacheProfile()
    return GitHubAccessInventory(
        account: GitHubAuthenticatedAccount(
            identity: profile.account
        ),
        installations: [
            GitHubInstallationAccess(
                installation: GitHubInstallation(
                    id: 1,
                    account: GitHubInstallationAccount(
                        id: "1",
                        login: "snow",
                        type: "Organization"
                    ),
                    repositorySelection: "all",
                    permissions: [
                        "actions": "read",
                        "pull_requests": "read",
                        "checks": "read",
                    ],
                    isSuspended: false
                ),
                repositories: repositories,
                status: .available
            ),
        ]
    )
}

private func retainedCacheCapabilities(
    repositories: [GitHubRepositoryAccess]
) -> GitHubConnectionCapabilityAssessment {
    GitHubConnectionCapabilityAssessment(
        repositories: Dictionary(
            uniqueKeysWithValues: repositories.map { repository in
                (
                    repository.id,
                    GitHubRepositoryCapabilityAssessment(
                        repositoryID: repository.id,
                        states: [
                            .actions: .available,
                            .pullRequests: .available,
                            .checks: .available,
                        ]
                    )
                )
            }
        )
    )
}

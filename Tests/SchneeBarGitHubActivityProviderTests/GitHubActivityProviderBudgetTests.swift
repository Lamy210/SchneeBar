import Foundation
import SchneeBarCore
import SchneeBarGitHub
import SchneeBarGitHubActivityProvider
import Testing

private actor BudgetWorkflowLoader: GitHubWorkflowRunLoading {
    private var calls: [Int64] = []

    func workflowRuns(
        connection: GitHubConnection,
        identity: GitHubAccountIdentity,
        clientID: String?,
        repository: GitHubRepositoryAccess,
        query: GitHubWorkflowRunQuery
    ) async throws -> [GitHubWorkflowRun] {
        calls.append(repository.id)
        let digit = String(format: "%x", repository.id % 16)
        let sha = String(repeating: digit, count: 40)
        return [
            GitHubWorkflowRun(
                id: repository.id * 10,
                workflowID: 1,
                name: "CI",
                displayTitle: "Build",
                event: "push",
                status: .completed,
                conclusion: .success,
                runNumber: 1,
                headBranch: "main",
                headSHA: sha,
                webURL: repository.webURL.appendingPathComponent("actions/runs/\(repository.id * 10)"),
                pullRequestNumbers: [],
                createdAt: Date(timeIntervalSince1970: 90),
                updatedAt: Date(timeIntervalSince1970: 100)
            ),
        ]
    }

    func count() -> Int { calls.count }
}

private actor RetainedBudgetWorkflowLoader:
    GitHubWorkflowRunLoading
{
    func workflowRuns(
        connection: GitHubConnection,
        identity: GitHubAccountIdentity,
        clientID: String?,
        repository: GitHubRepositoryAccess,
        query: GitHubWorkflowRunQuery
    ) async throws -> [GitHubWorkflowRun] {
        (0 ..< query.limit).map { index in
            let runID = repository.id * 1_000 + Int64(index + 1)
            return GitHubWorkflowRun(
                id: runID,
                workflowID: runID,
                name: "CI",
                displayTitle: "Build \(index)",
                event: "push",
                status: .completed,
                conclusion: .failure,
                runNumber: index + 1,
                headBranch: "main",
                headSHA: String(
                    format: "%040llx",
                    runID
                ),
                webURL: repository.webURL.appendingPathComponent(
                    "actions/runs/\(runID)"
                ),
                pullRequestNumbers: [],
                createdAt: Date(
                    timeIntervalSince1970:
                        TimeInterval(runID - 1)
                ),
                updatedAt: Date(
                    timeIntervalSince1970:
                        TimeInterval(runID)
                )
            )
        }
    }
}

private actor BudgetReviewLoader: GitHubReviewRequestLoading {
    private var calls: [Int64] = []

    func reviewRequests(
        connection: GitHubConnection,
        identity: GitHubAccountIdentity,
        clientID: String?,
        repository: GitHubRepositoryAccess
    ) async throws -> [GitHubReviewRequest] {
        calls.append(repository.id)
        return []
    }

    func count() -> Int { calls.count }
}

private actor FairBudgetReviewLoader: GitHubReviewRequestLoading {
    func reviewRequests(
        connection: GitHubConnection,
        identity: GitHubAccountIdentity,
        clientID: String?,
        repository: GitHubRepositoryAccess
    ) async throws -> [GitHubReviewRequest] {
        [
            GitHubReviewRequest(
                number: Int(repository.id),
                title: "Review \(repository.id)",
                headSHA: String(
                    format: "%040llx",
                    repository.id * 100 + 1
                ),
                isDraft: false,
                updatedAt: Date(timeIntervalSince1970: 100),
                requestedReviewerIDs: ["42"],
                webURL: repository.webURL.appendingPathComponent(
                    "pull/\(repository.id)"
                )
            ),
        ]
    }
}

private actor DeepFairBudgetReviewLoader: GitHubReviewRequestLoading {
    func reviewRequests(
        connection: GitHubConnection,
        identity: GitHubAccountIdentity,
        clientID: String?,
        repository: GitHubRepositoryAccess
    ) async throws -> [GitHubReviewRequest] {
        [1, 2].map { candidateIndex in
            GitHubReviewRequest(
                number: Int(repository.id * 10) + candidateIndex,
                title: "Review \(repository.id)-\(candidateIndex)",
                headSHA: String(
                    format: "%040llx",
                    repository.id * 100 + Int64(candidateIndex)
                ),
                isDraft: false,
                updatedAt: Date(
                    timeIntervalSince1970: TimeInterval(200 - candidateIndex)
                ),
                requestedReviewerIDs: ["42"],
                webURL: repository.webURL.appendingPathComponent(
                    "pull/\(repository.id * 10 + Int64(candidateIndex))"
                )
            )
        }
    }
}

private actor BudgetCancellationGate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        if isOpen {
            return
        }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    func open() {
        guard !isOpen else { return }
        isOpen = true
        let continuations = waiters
        waiters.removeAll()
        for continuation in continuations {
            continuation.resume()
        }
    }
}

private actor CancellationAwareBudgetWorkflowLoader: GitHubWorkflowRunLoading {
    private let releaseGate = BudgetCancellationGate()
    private var calls: [Int64] = []
    private var shouldBlock = true

    func workflowRuns(
        connection: GitHubConnection,
        identity: GitHubAccountIdentity,
        clientID: String?,
        repository: GitHubRepositoryAccess,
        query: GitHubWorkflowRunQuery
    ) async throws -> [GitHubWorkflowRun] {
        calls.append(repository.id)
        if shouldBlock {
            await releaseGate.wait()
            try Task.checkCancellation()
        }
        return []
    }

    func waitUntilCallCount(_ expectedCount: Int) async {
        while calls.count < expectedCount {
            await Task.yield()
        }
    }

    func release() async {
        shouldBlock = false
        await releaseGate.open()
    }

    func repositoryIDs() -> [Int64] {
        calls
    }
}

private actor CancellationAwareBudgetReviewLoader: GitHubReviewRequestLoading {
    private let releaseGate = BudgetCancellationGate()
    private var calls: [Int64] = []
    private var shouldBlock = true

    func reviewRequests(
        connection: GitHubConnection,
        identity: GitHubAccountIdentity,
        clientID: String?,
        repository: GitHubRepositoryAccess
    ) async throws -> [GitHubReviewRequest] {
        calls.append(repository.id)
        if shouldBlock {
            await releaseGate.wait()
            try Task.checkCancellation()
        }
        return []
    }

    func waitUntilCallCount(_ expectedCount: Int) async {
        while calls.count < expectedCount {
            await Task.yield()
        }
    }

    func release() async {
        shouldBlock = false
        await releaseGate.open()
    }

    func repositoryIDs() -> [Int64] {
        calls
    }
}

private actor CancellationAwareBudgetCheckLoader: GitHubCheckRunLoading {
    private let releaseGate = BudgetCancellationGate()
    private var calls: [Int64] = []
    private var shouldBlock = true

    func checkRuns(
        connection: GitHubConnection,
        identity: GitHubAccountIdentity,
        clientID: String?,
        repository: GitHubRepositoryAccess,
        headSHA: String
    ) async throws -> [GitHubCheckRun] {
        calls.append(repository.id)
        if shouldBlock {
            await releaseGate.wait()
            try Task.checkCancellation()
        }
        return []
    }

    func waitUntilCallCount(_ expectedCount: Int) async {
        while calls.count < expectedCount {
            await Task.yield()
        }
    }

    func release() async {
        shouldBlock = false
        await releaseGate.open()
    }

    func repositoryIDs() -> [Int64] {
        calls
    }
}

private actor BudgetCheckLoader: GitHubCheckRunLoading {
    private var calls: [(Int64, String)] = []

    func checkRuns(
        connection: GitHubConnection,
        identity: GitHubAccountIdentity,
        clientID: String?,
        repository: GitHubRepositoryAccess,
        headSHA: String
    ) async throws -> [GitHubCheckRun] {
        calls.append((repository.id, headSHA))
        return []
    }

    func count() -> Int { calls.count }

    func repositoryIDs() -> [Int64] {
        calls.map(\.0)
    }
}

@Test
func periodicRefreshNeverExceedsSixteenActivitySourceListRequests() async throws {
    let repositories = try (1 ... 12).map { id in
        try budgetRepository(id: Int64(id))
    }
    let workflow = BudgetWorkflowLoader()
    let reviews = BudgetReviewLoader()
    let checks = BudgetCheckLoader()
    let provider = GitHubActivityProvider(
        workflowRunLoader: workflow,
        reviewRequestLoader: reviews,
        checkRunLoader: checks,
        maximumConcurrentRepositories: 2,
        maximumRepositoriesPerRefresh: 8,
        maximumReviewRepositoriesPerRefresh: 4,
        maximumCheckTargetsPerRefresh: 4,
        maximumCheckTargetsPerRepository: 2,
        minimumColdRepositoriesPerRefresh: 1,
        minimumColdReviewRepositoriesPerRefresh: 1,
        now: { Date(timeIntervalSince1970: 100) }
    )

    let result = await provider.load(
        profile: try budgetProfile(),
        inventory: try budgetInventory(repositories: repositories),
        capabilities: budgetCapabilities(repositories: repositories)
    )

    let workflowCount = await workflow.count()
    let reviewCount = await reviews.count()
    let checkCount = await checks.count()
    #expect(workflowCount == 8)
    #expect(reviewCount == 4)
    #expect(checkCount == 4)
    #expect(workflowCount + reviewCount + checkCount == 16)
    #expect(result.surface(.workflows).attemptedTargetCount == 8)
    #expect(result.surface(.reviewRequests).attemptedTargetCount == 4)
    #expect(result.surface(.checks).attemptedTargetCount == 4)
}

@Test
func checkPollingRotatesAcrossRepositoriesBetweenRefreshes() async throws {
    let repositories = try (1 ... 6).map { id in
        try budgetRepository(id: Int64(id))
    }
    let checks = BudgetCheckLoader()
    let provider = GitHubActivityProvider(
        workflowRunLoader: BudgetWorkflowLoader(),
        reviewRequestLoader: FairBudgetReviewLoader(),
        checkRunLoader: checks,
        maximumConcurrentRepositories: 2,
        maximumRepositoriesPerRefresh: 6,
        maximumReviewRepositoriesPerRefresh: 6,
        maximumCheckTargetsPerRefresh: 4,
        maximumCheckTargetsPerRepository: 2,
        minimumColdRepositoriesPerRefresh: 6,
        minimumColdReviewRepositoriesPerRefresh: 6,
        now: { Date(timeIntervalSince1970: 100) }
    )
    let profile = try budgetProfile()
    let inventory = try budgetInventory(repositories: repositories)
    let capabilities = budgetCapabilities(repositories: repositories)

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

    let requestedRepositoryIDs = await checks.repositoryIDs()
    #expect(Set(requestedRepositoryIDs.prefix(4)) == Set([1, 2, 3, 4]))
    #expect(Set(requestedRepositoryIDs.suffix(4)) == Set([1, 2, 5, 6]))
    #expect(Set(requestedRepositoryIDs) == Set(repositories.map(\.id)))
}

@Test
func checkPollingRotatesSecondCandidateGrantsBetweenRefreshes() async throws {
    let repositories = try (1 ... 3).map { id in
        try budgetRepository(id: Int64(id))
    }
    let checks = BudgetCheckLoader()
    let provider = GitHubActivityProvider(
        workflowRunLoader: BudgetWorkflowLoader(),
        reviewRequestLoader: DeepFairBudgetReviewLoader(),
        checkRunLoader: checks,
        maximumConcurrentRepositories: 2,
        maximumRepositoriesPerRefresh: 3,
        maximumReviewRepositoriesPerRefresh: 3,
        maximumCheckTargetsPerRefresh: 4,
        maximumCheckTargetsPerRepository: 2,
        minimumColdRepositoriesPerRefresh: 3,
        minimumColdReviewRepositoriesPerRefresh: 3,
        now: { Date(timeIntervalSince1970: 100) }
    )
    let profile = try budgetProfile()
    let inventory = try budgetInventory(repositories: repositories)
    let capabilities = budgetCapabilities(repositories: repositories)

    for _ in 0 ..< 3 {
        _ = await provider.load(
            profile: profile,
            inventory: inventory,
            capabilities: capabilities
        )
    }

    let requestedRepositoryIDs = await checks.repositoryIDs()
    #expect(Array(requestedRepositoryIDs.prefix(4)) == [1, 2, 3, 1])
    #expect(Array(requestedRepositoryIDs.dropFirst(4).prefix(4)) == [2, 3, 1, 2])
    #expect(Array(requestedRepositoryIDs.suffix(4)) == [3, 1, 2, 3])
}

@Test
func cancelledWorkflowRefreshStopsQueuedRepositoriesAndPrioritizesUnattemptedRepositories() async throws {
    let repositories = try (1 ... 4).map { id in
        try budgetRepository(id: Int64(id))
    }
    let workflows = CancellationAwareBudgetWorkflowLoader()
    let provider = GitHubActivityProvider(
        workflowRunLoader: workflows,
        maximumConcurrentRepositories: 2,
        maximumRepositoriesPerRefresh: 4,
        minimumColdRepositoriesPerRefresh: 4,
        now: { Date(timeIntervalSince1970: 100) }
    )
    let profile = try budgetProfile()
    let inventory = try budgetInventory(repositories: repositories)
    let capabilities = budgetCapabilities(repositories: repositories)

    let cancelledRefresh = Task {
        await provider.load(
            profile: profile,
            inventory: inventory,
            capabilities: capabilities
        )
    }

    await workflows.waitUntilCallCount(2)
    cancelledRefresh.cancel()
    await workflows.release()
    _ = await cancelledRefresh.value

    let cancelledRepositoryIDs = await workflows.repositoryIDs()
    #expect(cancelledRepositoryIDs.count == 2)
    #expect(Set(cancelledRepositoryIDs) == Set([1, 2]))

    _ = await provider.load(
        profile: profile,
        inventory: inventory,
        capabilities: capabilities
    )

    let requestedRepositoryIDs = await workflows.repositoryIDs()
    #expect(requestedRepositoryIDs.count == 6)
    #expect(
        Set(requestedRepositoryIDs.dropFirst(2).prefix(2))
            == Set([3, 4])
    )
}

@Test
func cancelledReviewRefreshStopsQueuedRepositoriesAndPrioritizesUnattemptedRepositories() async throws {
    let repositories = try (1 ... 4).map { id in
        try budgetRepository(id: Int64(id))
    }
    let reviews = CancellationAwareBudgetReviewLoader()
    let provider = GitHubActivityProvider(
        workflowRunLoader: BudgetWorkflowLoader(),
        reviewRequestLoader: reviews,
        maximumConcurrentRepositories: 2,
        maximumRepositoriesPerRefresh: 4,
        maximumReviewRepositoriesPerRefresh: 4,
        minimumColdRepositoriesPerRefresh: 4,
        minimumColdReviewRepositoriesPerRefresh: 4,
        now: { Date(timeIntervalSince1970: 100) }
    )
    let profile = try budgetProfile()
    let inventory = try budgetInventory(repositories: repositories)
    let capabilities = budgetCapabilities(repositories: repositories)

    let cancelledRefresh = Task {
        await provider.load(
            profile: profile,
            inventory: inventory,
            capabilities: capabilities
        )
    }

    await reviews.waitUntilCallCount(2)
    cancelledRefresh.cancel()
    await reviews.release()
    _ = await cancelledRefresh.value

    let cancelledRepositoryIDs = await reviews.repositoryIDs()
    #expect(cancelledRepositoryIDs.count == 2)
    #expect(Set(cancelledRepositoryIDs) == Set([1, 2]))

    _ = await provider.load(
        profile: profile,
        inventory: inventory,
        capabilities: capabilities
    )

    let requestedRepositoryIDs = await reviews.repositoryIDs()
    #expect(requestedRepositoryIDs.count == 6)
    #expect(
        Set(requestedRepositoryIDs.dropFirst(2).prefix(2))
            == Set([3, 4])
    )
}

@Test
func cancelledCheckRefreshStopsQueuedTargetsAndPrioritizesUnattemptedRepositories() async throws {
    let repositories = try (1 ... 4).map { id in
        try budgetRepository(id: Int64(id))
    }
    let checks = CancellationAwareBudgetCheckLoader()
    let provider = GitHubActivityProvider(
        workflowRunLoader: BudgetWorkflowLoader(),
        reviewRequestLoader: FairBudgetReviewLoader(),
        checkRunLoader: checks,
        maximumConcurrentRepositories: 2,
        maximumRepositoriesPerRefresh: 4,
        maximumReviewRepositoriesPerRefresh: 4,
        maximumCheckTargetsPerRefresh: 4,
        maximumCheckTargetsPerRepository: 1,
        minimumColdRepositoriesPerRefresh: 4,
        minimumColdReviewRepositoriesPerRefresh: 4,
        now: { Date(timeIntervalSince1970: 100) }
    )
    let profile = try budgetProfile()
    let inventory = try budgetInventory(repositories: repositories)
    let capabilities = budgetCapabilities(repositories: repositories)

    let cancelledRefresh = Task {
        await provider.load(
            profile: profile,
            inventory: inventory,
            capabilities: capabilities
        )
    }

    await checks.waitUntilCallCount(2)
    cancelledRefresh.cancel()
    await checks.release()
    _ = await cancelledRefresh.value

    let cancelledRepositoryIDs = await checks.repositoryIDs()
    #expect(cancelledRepositoryIDs.count == 2)
    #expect(Set(cancelledRepositoryIDs) == Set([1, 2]))

    _ = await provider.load(
        profile: profile,
        inventory: inventory,
        capabilities: capabilities
    )

    let requestedRepositoryIDs = await checks.repositoryIDs()
    #expect(requestedRepositoryIDs.count == 6)
    #expect(
        Set(requestedRepositoryIDs.dropFirst(2).prefix(2))
            == Set([3, 4])
    )
}

@Test
func reenabledCheckCapabilityReentersPollingAsColdRepository() async throws {
    let repositories = try (1 ... 4).map { id in
        try budgetRepository(id: Int64(id))
    }
    let checks = BudgetCheckLoader()
    let provider = GitHubActivityProvider(
        workflowRunLoader: BudgetWorkflowLoader(),
        reviewRequestLoader: FairBudgetReviewLoader(),
        checkRunLoader: checks,
        maximumConcurrentRepositories: 2,
        maximumRepositoriesPerRefresh: 4,
        maximumReviewRepositoriesPerRefresh: 4,
        maximumCheckTargetsPerRefresh: 2,
        maximumCheckTargetsPerRepository: 1,
        minimumColdRepositoriesPerRefresh: 4,
        minimumColdReviewRepositoriesPerRefresh: 4,
        now: { Date(timeIntervalSince1970: 100) }
    )
    let profile = try budgetProfile()
    let inventory = try budgetInventory(repositories: repositories)

    _ = await provider.load(
        profile: profile,
        inventory: inventory,
        capabilities: budgetCapabilities(repositories: repositories)
    )

    var blockedRepositories: [Int64: GitHubRepositoryCapabilityAssessment] = [:]
    for repository in repositories {
        blockedRepositories[repository.id] = GitHubRepositoryCapabilityAssessment(
            repositoryID: repository.id,
            states: [
                .actions: .available,
                .pullRequests: .available,
                .checks: repository.id == 1
                    ? .unavailable(.missingPermission)
                    : .available,
            ]
        )
    }

    _ = await provider.load(
        profile: profile,
        inventory: inventory,
        capabilities: GitHubConnectionCapabilityAssessment(
            repositories: blockedRepositories
        )
    )

    _ = await provider.load(
        profile: profile,
        inventory: inventory,
        capabilities: budgetCapabilities(repositories: repositories)
    )

    let requestedRepositoryIDs = await checks.repositoryIDs()
    #expect(Set(requestedRepositoryIDs.prefix(2)) == Set([1, 2]))
    #expect(Set(requestedRepositoryIDs.dropFirst(2).prefix(2)) == Set([3, 4]))
    #expect(Set(requestedRepositoryIDs.suffix(2)) == Set([1, 2]))
}

@Test
func retainedRepositoryCacheProjectsIntoBoundedSourceSnapshot() async throws {
    let repositories = try (1 ... 103).map { id in
        try budgetRepository(id: Int64(id))
    }
    let provider = GitHubActivityProvider(
        workflowRunLoader: RetainedBudgetWorkflowLoader(),
        maximumConcurrentRepositories: 8,
        perRepositoryRunLimit: 20,
        maximumRepositoriesPerRefresh: 52,
        minimumColdRepositoriesPerRefresh: 52,
        cachePolicy: GitHubActivityCachePolicy(
            maximumWorkflowRepositories: 103
        ),
        now: { Date(timeIntervalSince1970: 100) }
    )
    let profile = try budgetProfile()
    let inventory = try budgetInventory(
        repositories: repositories
    )
    let capabilities = budgetCapabilities(
        repositories: repositories
    )

    let first = await provider.load(
        profile: profile,
        inventory: inventory,
        capabilities: capabilities
    )
    let second = await provider.load(
        profile: profile,
        inventory: inventory,
        capabilities: capabilities
    )

    #expect(first.items.count == 52 * 20)
    #expect(second.items.count == 103 * 20)

    let snapshot = ActivitySourceSnapshot.bounded(
        items: second.items,
        status: .available
    )
    #expect(
        snapshot.items.count
            == ActivitySourceCollectionPolicy.maximumItemsPerSource
    )
    #expect(snapshot.isTruncated)
}

private func budgetProfile() throws -> GitHubConnectionProfile {
    GitHubConnectionProfile(
        connection: GitHubConnection(
            id: UUID(uuidString: "62000000-0000-0000-0000-000000000001")!,
            displayName: "GitHub.com",
            deploymentKind: .githubDotCom,
            webBaseURL: try #require(URL(string: "https://github.com"))
        ),
        account: GitHubAccountIdentity(id: "42", login: "snow-user"),
        authenticationMethod: .deviceFlow,
        clientID: "Iv1.public-client-id",
        repositorySelection: .allAccessible,
        isEnabled: true
    )
}

private func budgetRepository(id: Int64) throws -> GitHubRepositoryAccess {
    let fullName = String(format: "snow/repo-%02lld", id)
    return GitHubRepositoryAccess(
        id: id,
        name: String(format: "repo-%02lld", id),
        fullName: fullName,
        isPrivate: false,
        webURL: try #require(URL(string: "https://github.com/\(fullName)")),
        ownerLogin: "snow",
        permissions: GitHubRepositoryPermissions(pull: true)
    )
}

private func budgetInventory(repositories: [GitHubRepositoryAccess]) throws -> GitHubAccessInventory {
    let profile = try budgetProfile()
    return GitHubAccessInventory(
        account: GitHubAuthenticatedAccount(identity: profile.account),
        installations: [
            GitHubInstallationAccess(
                installation: GitHubInstallation(
                    id: 1,
                    account: GitHubInstallationAccount(id: "1", login: "snow", type: "Organization"),
                    repositorySelection: "all",
                    permissions: ["actions": "read", "pull_requests": "read", "checks": "read"],
                    isSuspended: false
                ),
                repositories: repositories,
                status: .available
            ),
        ]
    )
}

private func budgetCapabilities(repositories: [GitHubRepositoryAccess]) -> GitHubConnectionCapabilityAssessment {
    GitHubConnectionCapabilityAssessment(
        repositories: Dictionary(
            uniqueKeysWithValues: repositories.map { repository in
                (
                    repository.id,
                    GitHubRepositoryCapabilityAssessment(
                        repositoryID: repository.id,
                        states: [.actions: .available, .pullRequests: .available, .checks: .available]
                    )
                )
            }
        )
    )
}

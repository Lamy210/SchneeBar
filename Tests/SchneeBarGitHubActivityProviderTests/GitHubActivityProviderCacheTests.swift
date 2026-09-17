import Foundation
import SchneeBarCore
import SchneeBarGitHub
import SchneeBarGitHubActivityProvider
import Testing

private enum CacheReviewStep: Sendable {
    case success([GitHubReviewRequest])
    case httpStatus(Int)
    case delayedSuccess([GitHubReviewRequest], UInt64)
}

private actor CacheReviewLoader: GitHubReviewRequestLoading {
    private let steps: [CacheReviewStep]
    private var index = 0

    init(steps: [CacheReviewStep]) {
        self.steps = steps
    }

    func reviewRequests(
        connection: GitHubConnection,
        identity: GitHubAccountIdentity,
        clientID: String?,
        repository: GitHubRepositoryAccess
    ) async throws -> [GitHubReviewRequest] {
        let step = steps[min(index, steps.count - 1)]
        index += 1
        switch step {
        case let .success(requests):
            return requests
        case let .httpStatus(status):
            throw GitHubPullRequestListClientError.httpStatus(status)
        case let .delayedSuccess(requests, delay):
            try await Task.sleep(nanoseconds: delay)
            return requests
        }
    }
}

private enum CacheWorkflowStep: Sendable {
    case success([GitHubWorkflowRun])
    case httpStatus(Int)
}

private actor CacheWorkflowLoader: GitHubWorkflowRunLoading {
    private let steps: [CacheWorkflowStep]
    private var index = 0

    init(runs: [GitHubWorkflowRun] = []) {
        steps = [.success(runs)]
    }

    init(steps: [CacheWorkflowStep]) {
        self.steps = steps
    }

    func workflowRuns(
        connection: GitHubConnection,
        identity: GitHubAccountIdentity,
        clientID: String?,
        repository: GitHubRepositoryAccess,
        query: GitHubWorkflowRunQuery
    ) async throws -> [GitHubWorkflowRun] {
        let step = steps[min(index, steps.count - 1)]
        index += 1
        switch step {
        case let .success(runs):
            return runs
        case let .httpStatus(status):
            throw GitHubActionsClientError.httpStatus(status)
        }
    }
}

private actor CacheCheckLoader: GitHubCheckRunLoading {
    private let responses: [[GitHubCheckRun]]
    private var index = 0

    init(responses: [[GitHubCheckRun]] = []) {
        self.responses = responses
    }

    func checkRuns(
        connection: GitHubConnection,
        identity: GitHubAccountIdentity,
        clientID: String?,
        repository: GitHubRepositoryAccess,
        headSHA: String
    ) async throws -> [GitHubCheckRun] {
        guard !responses.isEmpty else { return [] }
        let response = responses[min(index, responses.count - 1)]
        index += 1
        return response
    }
}

@Test
func successfulEmptyReviewResponseClearsCachedReviewItems() async throws {
    let repository = try cacheRepository()
    let request = try cacheReviewRequest(repository: repository)
    let provider = GitHubActivityProvider(
        workflowRunLoader: CacheWorkflowLoader(),
        reviewRequestLoader: CacheReviewLoader(steps: [.success([request]), .success([])]),
        checkRunLoader: CacheCheckLoader(),
        maximumConcurrentRepositories: 1
    )
    let profile = try cacheProfile()
    let inventory = try cacheInventory(repository: repository)
    let capabilities = cacheCapabilities(repositoryID: repository.id)

    let first = await provider.load(profile: profile, inventory: inventory, capabilities: capabilities)
    let second = await provider.load(profile: profile, inventory: inventory, capabilities: capabilities)

    #expect(first.surface(.reviewRequests).items.map(\.id) == ["github-review:1:7"])
    #expect(second.surface(.reviewRequests).items.isEmpty)
}

@Test
func reviewFailurePreservesLastKnownGoodReviewCacheAndReportsSourceFailure() async throws {
    let repository = try cacheRepository()
    let request = try cacheReviewRequest(repository: repository)
    let provider = GitHubActivityProvider(
        workflowRunLoader: CacheWorkflowLoader(),
        reviewRequestLoader: CacheReviewLoader(steps: [.success([request]), .httpStatus(403)]),
        checkRunLoader: CacheCheckLoader(),
        maximumConcurrentRepositories: 1
    )
    let profile = try cacheProfile()
    let inventory = try cacheInventory(repository: repository)
    let capabilities = cacheCapabilities(repositoryID: repository.id)

    _ = await provider.load(profile: profile, inventory: inventory, capabilities: capabilities)
    let failedRefresh = await provider.load(profile: profile, inventory: inventory, capabilities: capabilities)

    #expect(failedRefresh.surface(.reviewRequests).items.map(\.id) == ["github-review:1:7"])
    #expect(failedRefresh.surface(.reviewRequests).failures.map(\.reason) == [.forbidden])
}

@Test
func successfulEmptyCheckResponseClearsCachedCheckItemsForSameSHA() async throws {
    let repository = try cacheRepository()
    let sha = String(repeating: "c", count: 40)
    let workflow = try cacheWorkflowRun(repository: repository, headSHA: sha)
    let failedCheck = try cacheCheckRun(repository: repository, headSHA: sha)
    let provider = GitHubActivityProvider(
        workflowRunLoader: CacheWorkflowLoader(runs: [workflow]),
        reviewRequestLoader: CacheReviewLoader(steps: [.success([])]),
        checkRunLoader: CacheCheckLoader(responses: [[failedCheck], []]),
        maximumConcurrentRepositories: 1
    )
    let profile = try cacheProfile()
    let inventory = try cacheInventory(repository: repository)
    let capabilities = cacheCapabilities(repositoryID: repository.id)

    let first = await provider.load(profile: profile, inventory: inventory, capabilities: capabilities)
    let second = await provider.load(profile: profile, inventory: inventory, capabilities: capabilities)

    #expect(first.surface(.checks).items.map(\.id) == ["github-check:1:900"])
    #expect(second.surface(.checks).items.isEmpty)
}

@Test
func successfulWorkflowRefreshDropsPreviouslyCachedSupersededFailure() async throws {
    let repository = try cacheRepository()
    let old = try cacheWorkflowRun(
        repository: repository,
        headSHA: "aaa",
        id: 80,
        event: "pull_request",
        runNumber: 80,
        pullRequestNumbers: [120],
        status: .completed,
        conclusion: .failure,
        updatedAt: 100
    )
    let current = try cacheWorkflowRun(
        repository: repository,
        headSHA: "bbb",
        id: 81,
        event: "pull_request",
        runNumber: 81,
        pullRequestNumbers: [120],
        status: .inProgress,
        conclusion: nil,
        updatedAt: 200
    )
    let provider = GitHubActivityProvider(
        workflowRunLoader: CacheWorkflowLoader(steps: [.success([old]), .success([old, current])]),
        reviewRequestLoader: CacheReviewLoader(steps: [.success([])]),
        checkRunLoader: CacheCheckLoader(),
        maximumConcurrentRepositories: 1
    )
    let profile = try cacheProfile()
    let inventory = try cacheInventory(repository: repository)
    let capabilities = cacheCapabilities(repositoryID: repository.id)

    let first = await provider.load(profile: profile, inventory: inventory, capabilities: capabilities)
    let second = await provider.load(profile: profile, inventory: inventory, capabilities: capabilities)

    #expect(first.surface(.workflows).items.map(\.id) == ["github-actions:1:80"])
    #expect(second.surface(.workflows).items.map(\.id) == ["github-actions:1:81"])
}

@Test
func workflowFailurePreservesLastKnownGoodSupersessionResult() async throws {
    let repository = try cacheRepository()
    let current = try cacheWorkflowRun(
        repository: repository,
        headSHA: "bbb",
        id: 81,
        event: "pull_request",
        runNumber: 81,
        pullRequestNumbers: [120],
        status: .inProgress,
        conclusion: nil,
        updatedAt: 200
    )
    let provider = GitHubActivityProvider(
        workflowRunLoader: CacheWorkflowLoader(steps: [.success([current]), .httpStatus(503)]),
        reviewRequestLoader: CacheReviewLoader(steps: [.success([])]),
        checkRunLoader: CacheCheckLoader(),
        maximumConcurrentRepositories: 1
    )
    let profile = try cacheProfile()
    let inventory = try cacheInventory(repository: repository)
    let capabilities = cacheCapabilities(repositoryID: repository.id)

    _ = await provider.load(profile: profile, inventory: inventory, capabilities: capabilities)
    let failed = await provider.load(profile: profile, inventory: inventory, capabilities: capabilities)

    #expect(failed.surface(.workflows).items.map(\.id) == ["github-actions:1:81"])
    #expect(failed.surface(.workflows).failures.map(\.reason) == [.unavailable])
}

@Test
func review401IsReportedAsAuthenticationRequiredForReviewSurface() async throws {
    let repository = try cacheRepository()
    let provider = GitHubActivityProvider(
        workflowRunLoader: CacheWorkflowLoader(),
        reviewRequestLoader: CacheReviewLoader(steps: [.httpStatus(401)]),
        checkRunLoader: CacheCheckLoader(),
        maximumConcurrentRepositories: 1
    )

    let result = await provider.load(
        profile: try cacheProfile(),
        inventory: try cacheInventory(repository: repository),
        capabilities: cacheCapabilities(repositoryID: repository.id)
    )

    #expect(result.surface(.reviewRequests).failures.map(\.reason) == [.authenticationRequired])
}

@Test
func resetDuringReviewLoadDiscardsStaleReviewCompletion() async throws {
    let repository = try cacheRepository()
    let request = try cacheReviewRequest(repository: repository)
    let provider = GitHubActivityProvider(
        workflowRunLoader: CacheWorkflowLoader(),
        reviewRequestLoader: CacheReviewLoader(
            steps: [.delayedSuccess([request], 100_000_000)]
        ),
        checkRunLoader: CacheCheckLoader(),
        maximumConcurrentRepositories: 1
    )
    let profile = try cacheProfile()
    let inventory = try cacheInventory(repository: repository)
    let capabilities = cacheCapabilities(repositoryID: repository.id)

    async let loading = provider.load(
        profile: profile,
        inventory: inventory,
        capabilities: capabilities
    )
    try await Task.sleep(nanoseconds: 10_000_000)
    await provider.reset(connectionID: profile.id)
    let stale = await loading

    #expect(stale.items.isEmpty)
    #expect(stale.surface(.reviewRequests).items.isEmpty)
}

private func cacheProfile() throws -> GitHubConnectionProfile {
    GitHubConnectionProfile(
        connection: GitHubConnection(
            id: UUID(uuidString: "63000000-0000-0000-0000-000000000001")!,
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

private func cacheRepository() throws -> GitHubRepositoryAccess {
    GitHubRepositoryAccess(
        id: 1,
        name: "app",
        fullName: "snow/app",
        isPrivate: false,
        webURL: try #require(URL(string: "https://github.com/snow/app")),
        ownerLogin: "snow",
        permissions: GitHubRepositoryPermissions(pull: true)
    )
}

private func cacheInventory(repository: GitHubRepositoryAccess) throws -> GitHubAccessInventory {
    let profile = try cacheProfile()
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
                repositories: [repository],
                status: .available
            ),
        ]
    )
}

private func cacheCapabilities(repositoryID: Int64) -> GitHubConnectionCapabilityAssessment {
    GitHubConnectionCapabilityAssessment(
        repositories: [
            repositoryID: GitHubRepositoryCapabilityAssessment(
                repositoryID: repositoryID,
                states: [.actions: .available, .pullRequests: .available, .checks: .available]
            ),
        ]
    )
}

private func cacheReviewRequest(repository: GitHubRepositoryAccess) throws -> GitHubReviewRequest {
    GitHubReviewRequest(
        number: 7,
        title: "Review cache",
        headSHA: String(repeating: "d", count: 40),
        isDraft: false,
        updatedAt: Date(timeIntervalSince1970: 100),
        requestedReviewerIDs: ["42"],
        webURL: try #require(URL(string: "\(repository.webURL.absoluteString)/pull/7"))
    )
}

private func cacheWorkflowRun(
    repository: GitHubRepositoryAccess,
    headSHA: String,
    id: Int64 = 11,
    event: String = "push",
    runNumber: Int = 1,
    pullRequestNumbers: [Int] = [],
    status: GitHubWorkflowRunStatus = .completed,
    conclusion: GitHubWorkflowRunConclusion? = .success,
    updatedAt: TimeInterval = 100
) throws -> GitHubWorkflowRun {
    GitHubWorkflowRun(
        id: id,
        workflowID: 1,
        name: "CI",
        displayTitle: "Build",
        event: event,
        status: status,
        conclusion: conclusion,
        runNumber: runNumber,
        headBranch: "main",
        headSHA: headSHA,
        webURL: try #require(URL(string: "\(repository.webURL.absoluteString)/actions/runs/\(id)")),
        pullRequestNumbers: pullRequestNumbers,
        createdAt: Date(timeIntervalSince1970: updatedAt - 10),
        updatedAt: Date(timeIntervalSince1970: updatedAt)
    )
}

private func cacheCheckRun(
    repository: GitHubRepositoryAccess,
    headSHA: String
) throws -> GitHubCheckRun {
    GitHubCheckRun(
        id: 900,
        name: "Coverage",
        status: .completed,
        conclusion: .failure,
        appSlug: "codecov",
        headSHA: headSHA,
        startedAt: Date(timeIntervalSince1970: 95),
        completedAt: Date(timeIntervalSince1970: 105),
        webURL: try #require(URL(string: "\(repository.webURL.absoluteString)/commit/\(headSHA)/checks"))
    )
}

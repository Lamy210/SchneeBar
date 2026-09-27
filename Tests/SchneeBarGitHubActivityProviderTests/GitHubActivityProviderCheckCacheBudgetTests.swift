import Foundation
import SchneeBarCore
import SchneeBarGitHub
import SchneeBarGitHubActivityProvider
import Testing

private actor CheckCacheBudgetWorkflowLoader: GitHubWorkflowRunLoading {
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

private actor CheckCacheBudgetReviewLoader: GitHubReviewRequestLoading {
    private let responses: [Int64: [[GitHubReviewRequest]]]
    private var indexByRepositoryID: [Int64: Int] = [:]

    init(responses: [Int64: [[GitHubReviewRequest]]]) {
        self.responses = responses
    }

    func reviewRequests(
        connection: GitHubConnection,
        identity: GitHubAccountIdentity,
        clientID: String?,
        repository: GitHubRepositoryAccess
    ) async throws -> [GitHubReviewRequest] {
        let index = indexByRepositoryID[repository.id, default: 0]
        indexByRepositoryID[repository.id] = index + 1
        let steps = responses[repository.id, default: [[]]]
        return steps[min(index, steps.count - 1)]
    }
}

private actor CheckCacheBudgetCheckLoader: GitHubCheckRunLoading {
    private let responsesBySHA: [String: [GitHubCheckRun]]
    private var calls: [String] = []

    init(responsesBySHA: [String: [GitHubCheckRun]]) {
        self.responsesBySHA = responsesBySHA
    }

    func checkRuns(
        connection: GitHubConnection,
        identity: GitHubAccountIdentity,
        clientID: String?,
        repository: GitHubRepositoryAccess,
        headSHA: String
    ) async throws -> [GitHubCheckRun] {
        calls.append(headSHA)
        return responsesBySHA[headSHA, default: []]
    }

    func recordedCalls() -> [String] {
        calls
    }
}

@Test
func globalCheckBudgetDoesNotPruneStillValidUnpolledCache() async throws {
    let repositoryA = try checkCacheBudgetRepository(
        id: 1,
        name: "a-repo"
    )
    let repositoryB = try checkCacheBudgetRepository(
        id: 2,
        name: "b-repo"
    )
    let shaA = String(repeating: "a", count: 40)
    let shaB = String(repeating: "b", count: 40)
    let reviewA = try checkCacheBudgetReviewRequest(
        number: 11,
        repository: repositoryA,
        headSHA: shaA
    )
    let reviewB = try checkCacheBudgetReviewRequest(
        number: 22,
        repository: repositoryB,
        headSHA: shaB
    )
    let reviews = CheckCacheBudgetReviewLoader(
        responses: [
            repositoryA.id: [[], [reviewA], [reviewA]],
            repositoryB.id: [[reviewB], [reviewB], []],
        ]
    )
    let checks = CheckCacheBudgetCheckLoader(
        responsesBySHA: [
            shaA: [
                try checkCacheBudgetCheckRun(
                    id: 101,
                    repository: repositoryA,
                    headSHA: shaA
                ),
            ],
            shaB: [
                try checkCacheBudgetCheckRun(
                    id: 202,
                    repository: repositoryB,
                    headSHA: shaB
                ),
            ],
        ]
    )
    let provider = GitHubActivityProvider(
        workflowRunLoader: CheckCacheBudgetWorkflowLoader(),
        reviewRequestLoader: reviews,
        checkRunLoader: checks,
        maximumConcurrentRepositories: 1,
        maximumRepositoriesPerRefresh: 2,
        maximumReviewRepositoriesPerRefresh: 2,
        maximumCheckTargetsPerRefresh: 1,
        maximumCheckTargetsPerRepository: 1,
        minimumColdRepositoriesPerRefresh: 0,
        minimumColdReviewRepositoriesPerRefresh: 0,
        now: { Date(timeIntervalSince1970: 100) }
    )
    let repositories = [repositoryA, repositoryB]
    let profile = try checkCacheBudgetProfile()
    let inventory = try checkCacheBudgetInventory(
        repositories: repositories
    )
    let capabilities = checkCacheBudgetCapabilities(
        repositories: repositories
    )

    let first = await provider.load(
        profile: profile,
        inventory: inventory,
        capabilities: capabilities
    )
    #expect(
        first.surface(.checks).items.map(\.repository)
            == ["snow/b-repo"]
    )

    let second = await provider.load(
        profile: profile,
        inventory: inventory,
        capabilities: capabilities
    )
    #expect(
        second.surface(.checks).items.map(\.repository)
            == ["snow/a-repo", "snow/b-repo"]
    )

    let third = await provider.load(
        profile: profile,
        inventory: inventory,
        capabilities: capabilities
    )
    #expect(
        third.surface(.checks).items.map(\.repository)
            == ["snow/a-repo"]
    )
    #expect(await checks.recordedCalls() == [shaB, shaA, shaA])
}

private func checkCacheBudgetProfile() throws -> GitHubConnectionProfile {
    GitHubConnectionProfile(
        connection: GitHubConnection(
            id: UUID(
                uuidString:
                    "65000000-0000-0000-0000-000000000001"
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

private func checkCacheBudgetRepository(
    id: Int64,
    name: String
) throws -> GitHubRepositoryAccess {
    let fullName = "snow/\(name)"
    return GitHubRepositoryAccess(
        id: id,
        name: name,
        fullName: fullName,
        isPrivate: false,
        webURL: try #require(
            URL(string: "https://github.com/\(fullName)")
        ),
        ownerLogin: "snow",
        permissions: GitHubRepositoryPermissions(pull: true)
    )
}

private func checkCacheBudgetInventory(
    repositories: [GitHubRepositoryAccess]
) throws -> GitHubAccessInventory {
    let profile = try checkCacheBudgetProfile()
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

private func checkCacheBudgetCapabilities(
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

private func checkCacheBudgetReviewRequest(
    number: Int,
    repository: GitHubRepositoryAccess,
    headSHA: String
) throws -> GitHubReviewRequest {
    GitHubReviewRequest(
        number: number,
        title: "Review \(number)",
        headSHA: headSHA,
        isDraft: false,
        updatedAt: Date(timeIntervalSince1970: Double(number)),
        requestedReviewerIDs: ["42"],
        webURL: try #require(
            URL(
                string:
                    "\(repository.webURL.absoluteString)/pull/\(number)"
            )
        )
    )
}

private func checkCacheBudgetCheckRun(
    id: Int64,
    repository: GitHubRepositoryAccess,
    headSHA: String
) throws -> GitHubCheckRun {
    GitHubCheckRun(
        id: id,
        name: "External CI",
        status: .completed,
        conclusion: .failure,
        appSlug: "external-ci",
        headSHA: headSHA,
        startedAt: Date(timeIntervalSince1970: 90),
        completedAt: Date(timeIntervalSince1970: 100),
        webURL: try #require(
            URL(
                string:
                    "\(repository.webURL.absoluteString)/commit/\(headSHA)/checks"
            )
        )
    )
}

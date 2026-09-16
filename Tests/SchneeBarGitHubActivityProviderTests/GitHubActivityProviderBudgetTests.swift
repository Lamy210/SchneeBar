import Foundation
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

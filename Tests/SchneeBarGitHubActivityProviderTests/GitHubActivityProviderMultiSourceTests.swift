import Foundation
import SchneeBarCore
import SchneeBarGitHub
import SchneeBarGitHubActivityProvider
import Testing

private actor MultiSourceWorkflowLoader: GitHubWorkflowRunLoading {
    private let responses: [Int64: [GitHubWorkflowRun]]
    private var calls: [Int64] = []

    init(responses: [Int64: [GitHubWorkflowRun]] = [:]) {
        self.responses = responses
    }

    func workflowRuns(
        connection: GitHubConnection,
        identity: GitHubAccountIdentity,
        clientID: String?,
        repository: GitHubRepositoryAccess,
        query: GitHubWorkflowRunQuery
    ) async throws -> [GitHubWorkflowRun] {
        calls.append(repository.id)
        return responses[repository.id, default: []]
    }

    func requestedRepositoryIDs() -> [Int64] {
        calls
    }
}

private actor MultiSourceReviewLoader: GitHubReviewRequestLoading {
    private let responses: [Int64: [GitHubReviewRequest]]
    private var calls: [Int64] = []

    init(responses: [Int64: [GitHubReviewRequest]] = [:]) {
        self.responses = responses
    }

    func reviewRequests(
        connection: GitHubConnection,
        identity: GitHubAccountIdentity,
        clientID: String?,
        repository: GitHubRepositoryAccess
    ) async throws -> [GitHubReviewRequest] {
        calls.append(repository.id)
        return responses[repository.id, default: []]
    }

    func requestedRepositoryIDs() -> [Int64] {
        calls
    }
}

private struct MultiSourceCheckRequest: Equatable, Sendable {
    let repositoryID: Int64
    let headSHA: String
}

private actor MultiSourceCheckLoader: GitHubCheckRunLoading {
    private let responses: [String: [GitHubCheckRun]]
    private var calls: [MultiSourceCheckRequest] = []

    init(responses: [String: [GitHubCheckRun]] = [:]) {
        self.responses = responses
    }

    func checkRuns(
        connection: GitHubConnection,
        identity: GitHubAccountIdentity,
        clientID: String?,
        repository: GitHubRepositoryAccess,
        headSHA: String
    ) async throws -> [GitHubCheckRun] {
        calls.append(MultiSourceCheckRequest(repositoryID: repository.id, headSHA: headSHA))
        return responses["\(repository.id):\(headSHA)", default: []]
    }

    func requestedChecks() -> [MultiSourceCheckRequest] {
        calls
    }
}

@Test
func capabilityUnavailableBlocksReviewAndChecksWithoutSourceRequests() async throws {
    let repository = try multiSourceRepository(id: 1, fullName: "snow/app")
    let sha = String(repeating: "a", count: 40)
    let workflowLoader = MultiSourceWorkflowLoader(responses: [
        1: [try multiSourceWorkflowRun(id: 10, repository: repository, headSHA: sha, status: .inProgress, conclusion: nil)],
    ])
    let reviewLoader = MultiSourceReviewLoader()
    let checkLoader = MultiSourceCheckLoader()
    let provider = GitHubActivityProvider(
        workflowRunLoader: workflowLoader,
        reviewRequestLoader: reviewLoader,
        checkRunLoader: checkLoader,
        maximumConcurrentRepositories: 1
    )
    let capabilities = GitHubConnectionCapabilityAssessment(
        repositories: [
            1: GitHubRepositoryCapabilityAssessment(
                repositoryID: 1,
                states: [
                    .actions: .available,
                    .pullRequests: .unavailable(.missingPermission),
                    .checks: .unavailable(.missingPermission),
                ]
            ),
        ]
    )

    let result = await provider.load(
        profile: try multiSourceProfile(),
        inventory: try multiSourceInventory(repositories: [repository]),
        capabilities: capabilities
    )

    #expect(await workflowLoader.requestedRepositoryIDs() == [1])
    #expect(await reviewLoader.requestedRepositoryIDs().isEmpty)
    #expect(await checkLoader.requestedChecks().isEmpty)
    #expect(result.surface(.workflows).attemptedTargetCount == 1)
    #expect(result.surface(.reviewRequests).blockedTargetCount == 1)
    #expect(result.surface(.checks).blockedTargetCount == 1)
}

@Test
func hiddenSuccessfulWorkflowStillDiscoversExternalFailedCheck() async throws {
    let repository = try multiSourceRepository(id: 1, fullName: "snow/app")
    let sha = String(repeating: "b", count: 40)
    let workflowLoader = MultiSourceWorkflowLoader(responses: [
        1: [try multiSourceWorkflowRun(id: 11, repository: repository, headSHA: sha, status: .completed, conclusion: .success)],
    ])
    let reviewLoader = MultiSourceReviewLoader()
    let failedCheck = try multiSourceCheckRun(
        id: 900,
        repository: repository,
        headSHA: sha,
        appSlug: "codecov",
        conclusion: .failure
    )
    let checkLoader = MultiSourceCheckLoader(responses: ["1:\(sha)": [failedCheck]])
    let provider = GitHubActivityProvider(
        workflowRunLoader: workflowLoader,
        reviewRequestLoader: reviewLoader,
        checkRunLoader: checkLoader,
        maximumConcurrentRepositories: 1
    )

    let result = await provider.load(
        profile: try multiSourceProfile(),
        inventory: try multiSourceInventory(repositories: [repository]),
        capabilities: multiSourceCapabilities(repositoryID: 1)
    )

    #expect(result.surface(.workflows).items.isEmpty)
    #expect(result.surface(.checks).items.map(\.id) == ["github-check:1:900"])
    #expect(result.items.map(\.id) == ["github-check:1:900"])
    #expect(result.items.first?.kind == .checkRun)
    #expect(await checkLoader.requestedChecks() == [MultiSourceCheckRequest(repositoryID: 1, headSHA: sha)])
}

private func multiSourceCapabilities(repositoryID: Int64) -> GitHubConnectionCapabilityAssessment {
    GitHubConnectionCapabilityAssessment(
        repositories: [
            repositoryID: GitHubRepositoryCapabilityAssessment(
                repositoryID: repositoryID,
                states: [
                    .actions: .available,
                    .pullRequests: .available,
                    .checks: .available,
                ]
            ),
        ]
    )
}

private func multiSourceProfile() throws -> GitHubConnectionProfile {
    GitHubConnectionProfile(
        connection: GitHubConnection(
            id: UUID(uuidString: "61000000-0000-0000-0000-000000000001")!,
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

private func multiSourceInventory(repositories: [GitHubRepositoryAccess]) throws -> GitHubAccessInventory {
    let profile = try multiSourceProfile()
    return GitHubAccessInventory(
        account: GitHubAuthenticatedAccount(identity: profile.account),
        installations: [
            GitHubInstallationAccess(
                installation: GitHubInstallation(
                    id: 1,
                    account: GitHubInstallationAccount(id: "1", login: "snow", type: "Organization"),
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

private func multiSourceRepository(id: Int64, fullName: String) throws -> GitHubRepositoryAccess {
    let parts = fullName.split(separator: "/", maxSplits: 1).map(String.init)
    return GitHubRepositoryAccess(
        id: id,
        name: try #require(parts.last),
        fullName: fullName,
        isPrivate: false,
        webURL: try #require(URL(string: "https://github.com/\(fullName)")),
        ownerLogin: try #require(parts.first),
        permissions: GitHubRepositoryPermissions(pull: true)
    )
}

private func multiSourceWorkflowRun(
    id: Int64,
    repository: GitHubRepositoryAccess,
    headSHA: String,
    status: GitHubWorkflowRunStatus,
    conclusion: GitHubWorkflowRunConclusion?
) throws -> GitHubWorkflowRun {
    GitHubWorkflowRun(
        id: id,
        workflowID: 100,
        name: "CI",
        displayTitle: "Build",
        event: "push",
        status: status,
        conclusion: conclusion,
        runNumber: 1,
        headBranch: "main",
        headSHA: headSHA,
        webURL: try #require(URL(string: "\(repository.webURL.absoluteString)/actions/runs/\(id)")),
        pullRequestNumbers: [],
        createdAt: Date(timeIntervalSince1970: 90),
        updatedAt: Date(timeIntervalSince1970: 100)
    )
}

private func multiSourceCheckRun(
    id: Int64,
    repository: GitHubRepositoryAccess,
    headSHA: String,
    appSlug: String,
    conclusion: GitHubCheckRunConclusion
) throws -> GitHubCheckRun {
    GitHubCheckRun(
        id: id,
        name: "Coverage",
        status: .completed,
        conclusion: conclusion,
        appSlug: appSlug,
        headSHA: headSHA,
        startedAt: Date(timeIntervalSince1970: 95),
        completedAt: Date(timeIntervalSince1970: 105),
        webURL: try #require(URL(string: "\(repository.webURL.absoluteString)/commit/\(headSHA)/checks"))
    )
}

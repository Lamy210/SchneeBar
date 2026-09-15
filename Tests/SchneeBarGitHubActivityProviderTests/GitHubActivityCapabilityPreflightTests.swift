import Foundation
import SchneeBarGitHub
import SchneeBarGitHubActivityProvider
import Testing

private actor CapabilityActivityLoaderStub: GitHubWorkflowRunLoading {
    private var requestedRepositoryIDs: [Int64] = []

    func workflowRuns(
        connection: GitHubConnection,
        identity: GitHubAccountIdentity,
        clientID: String?,
        repository: GitHubRepositoryAccess,
        query: GitHubWorkflowRunQuery
    ) async throws -> [GitHubWorkflowRun] {
        requestedRepositoryIDs.append(repository.id)
        return []
    }

    func requestedIDs() -> [Int64] {
        requestedRepositoryIDs
    }
}

@Test
func actionsUnavailableSkipsWorkflowRequestAndCountsBlock() async throws {
    let repository = try capabilityActivityRepository(
        id: 1,
        fullName: "example-org/private",
        isPrivate: true
    )
    let loader = CapabilityActivityLoaderStub()
    let provider = GitHubActivityProvider(workflowRunLoader: loader)
    let profile = try capabilityActivityProfile()
    let inventory = capabilityActivityInventory(repositories: [repository])
    let capabilities = capabilityActivityAssessment(
        repositoryID: 1,
        state: .unavailable(.missingPermission)
    )

    let result = await provider.load(
        profile: profile,
        inventory: inventory,
        capabilities: capabilities
    )

    #expect(await loader.requestedIDs().isEmpty)
    #expect(result.attemptedRepositoryCount == 0)
    #expect(result.blockedRepositoryCount == 1)
    #expect(result.consideredRepositoryCount == 1)
    #expect(
        result.failures == [
            GitHubRepositoryActivityFailure(
                repositoryID: 1,
                repositoryFullName: "example-org/private",
                reason: .capabilityUnavailable
            ),
        ]
    )
}

@Test
func unknownActionsCapabilityStillAttemptsWorkflowRequest() async throws {
    let repository = try capabilityActivityRepository(
        id: 1,
        fullName: "example-org/public",
        isPrivate: false
    )
    let loader = CapabilityActivityLoaderStub()
    let provider = GitHubActivityProvider(workflowRunLoader: loader)
    let capabilities = capabilityActivityAssessment(
        repositoryID: 1,
        state: .unknown([.publicRepositoryPermissionNotProven])
    )

    let result = await provider.load(
        profile: try capabilityActivityProfile(),
        inventory: capabilityActivityInventory(repositories: [repository]),
        capabilities: capabilities
    )

    #expect(await loader.requestedIDs() == [1])
    #expect(result.attemptedRepositoryCount == 1)
    #expect(result.blockedRepositoryCount == 0)
}

@Test
func availableActionsCapabilityRetainsExistingPollBehavior() async throws {
    let repository = try capabilityActivityRepository(
        id: 1,
        fullName: "example-org/private",
        isPrivate: true
    )
    let loader = CapabilityActivityLoaderStub()
    let provider = GitHubActivityProvider(workflowRunLoader: loader)

    let result = await provider.load(
        profile: try capabilityActivityProfile(),
        inventory: capabilityActivityInventory(repositories: [repository]),
        capabilities: capabilityActivityAssessment(repositoryID: 1, state: .available)
    )

    #expect(await loader.requestedIDs() == [1])
    #expect(result.attemptedRepositoryCount == 1)
    #expect(result.blockedRepositoryCount == 0)
}

@Test
func missingCapabilityAssessmentRetainsExistingPollBehavior() async throws {
    let repository = try capabilityActivityRepository(
        id: 1,
        fullName: "example-org/private",
        isPrivate: true
    )
    let loader = CapabilityActivityLoaderStub()
    let provider = GitHubActivityProvider(workflowRunLoader: loader)

    let result = await provider.load(
        profile: try capabilityActivityProfile(),
        inventory: capabilityActivityInventory(repositories: [repository]),
        capabilities: nil
    )

    #expect(await loader.requestedIDs() == [1])
    #expect(result.attemptedRepositoryCount == 1)
    #expect(result.blockedRepositoryCount == 0)
}

@Test
func blockedRepositoriesDoNotConsumeNetworkPollingBudget() async throws {
    let repositories = try (1 ... 6).map { id in
        try capabilityActivityRepository(
            id: Int64(id),
            fullName: String(format: "example-org/repo-%02d", id),
            isPrivate: id == 1
        )
    }
    let loader = CapabilityActivityLoaderStub()
    let provider = GitHubActivityProvider(
        workflowRunLoader: loader,
        maximumConcurrentRepositories: 1,
        maximumRepositoriesPerRefresh: 3,
        minimumColdRepositoriesPerRefresh: 1,
        now: { Date(timeIntervalSince1970: 100) }
    )
    let capabilities = GitHubConnectionCapabilityAssessment(
        repositories: [
            1: GitHubRepositoryCapabilityAssessment(
                repositoryID: 1,
                states: [.actions: .unavailable(.missingPermission)]
            ),
        ]
    )
    let profile = try capabilityActivityProfile()
    let inventory = capabilityActivityInventory(repositories: repositories)

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

    #expect(first.attemptedRepositoryCount == 3)
    #expect(first.blockedRepositoryCount == 1)
    #expect(first.consideredRepositoryCount == 4)
    #expect(second.attemptedRepositoryCount == 3)
    #expect(second.blockedRepositoryCount == 1)

    let requested = await loader.requestedIDs()
    #expect(Array(requested.prefix(3)) == [2, 3, 4])
    #expect(Array(requested.suffix(3)) == [5, 6, 2])
    #expect(!requested.contains(1))
}

private func capabilityActivityAssessment(
    repositoryID: Int64,
    state: GitHubCapabilityState
) -> GitHubConnectionCapabilityAssessment {
    GitHubConnectionCapabilityAssessment(
        repositories: [
            repositoryID: GitHubRepositoryCapabilityAssessment(
                repositoryID: repositoryID,
                states: [.actions: state]
            ),
        ]
    )
}

private func capabilityActivityProfile() throws -> GitHubConnectionProfile {
    GitHubConnectionProfile(
        connection: GitHubConnection(
            id: UUID(uuidString: "30000000-0000-0000-0000-000000000001")!,
            displayName: "GitHub.com",
            deploymentKind: .githubDotCom,
            webBaseURL: try #require(URL(string: "https://github.com"))
        ),
        account: GitHubAccountIdentity(id: "100", login: "octocat"),
        authenticationMethod: .deviceFlow,
        clientID: "Iv1.public-client-id",
        repositorySelection: .allAccessible,
        isEnabled: true
    )
}

private func capabilityActivityInventory(
    repositories: [GitHubRepositoryAccess]
) -> GitHubAccessInventory {
    GitHubAccessInventory(
        account: GitHubAuthenticatedAccount(
            identity: GitHubAccountIdentity(id: "100", login: "octocat")
        ),
        installations: [
            GitHubInstallationAccess(
                installation: GitHubInstallation(
                    id: 1,
                    account: GitHubInstallationAccount(
                        id: "1",
                        login: "example-org",
                        type: "Organization"
                    ),
                    repositorySelection: "all",
                    permissions: ["actions": "read"],
                    isSuspended: false
                ),
                repositories: repositories,
                status: .available
            ),
        ]
    )
}

private func capabilityActivityRepository(
    id: Int64,
    fullName: String,
    isPrivate: Bool
) throws -> GitHubRepositoryAccess {
    let parts = fullName.split(separator: "/", maxSplits: 1).map(String.init)
    let owner = try #require(parts.first)
    let name = try #require(parts.last)
    return GitHubRepositoryAccess(
        id: id,
        name: name,
        fullName: fullName,
        isPrivate: isPrivate,
        webURL: try #require(URL(string: "https://github.com/\(fullName)")),
        ownerLogin: owner,
        permissions: GitHubRepositoryPermissions(pull: true)
    )
}

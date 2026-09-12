import Foundation
import SchneeBarCore
import SchneeBarGitHub
import SchneeBarGitHubActivityProvider
import Testing

private enum ActivityLoaderStubError: Error, Sendable {
    case forbidden
}

private actor ActivityLoaderStub: GitHubWorkflowRunLoading {
    private let responses: [Int64: Result<[GitHubWorkflowRun], ActivityLoaderStubError>]
    private let delayNanoseconds: UInt64
    private var requestedRepositoryIDs: [Int64] = []
    private var currentRequests = 0
    private var maximumObservedRequests = 0

    init(
        responses: [Int64: Result<[GitHubWorkflowRun], ActivityLoaderStubError>],
        delayNanoseconds: UInt64 = 0
    ) {
        self.responses = responses
        self.delayNanoseconds = delayNanoseconds
    }

    func workflowRuns(
        connection: GitHubConnection,
        identity: GitHubAccountIdentity,
        clientID: String?,
        repository: GitHubRepositoryAccess,
        query: GitHubWorkflowRunQuery
    ) async throws -> [GitHubWorkflowRun] {
        requestedRepositoryIDs.append(repository.id)
        currentRequests += 1
        maximumObservedRequests = max(maximumObservedRequests, currentRequests)
        defer { currentRequests -= 1 }

        if delayNanoseconds > 0 {
            try await Task.sleep(nanoseconds: delayNanoseconds)
        }

        switch responses[repository.id] ?? .success([]) {
        case let .success(runs):
            return runs
        case .failure:
            throw GitHubActionsClientError.httpStatus(403)
        }
    }

    func requestedIDs() -> [Int64] {
        requestedRepositoryIDs
    }

    func maximumConcurrency() -> Int {
        maximumObservedRequests
    }
}

@Test
func loadsOnlySelectedAccessibleRepositoriesAndOrdersAttentionFirst() async throws {
    let failedRepository = try repository(id: 1, fullName: "acme/api")
    let runningRepository = try repository(id: 2, fullName: "acme/web")
    let excludedRepository = try repository(id: 3, fullName: "acme/docs")

    let loader = ActivityLoaderStub(responses: [
        1: .success([
            try workflowRun(
                id: 11,
                repository: failedRepository,
                status: .completed,
                conclusion: .failure,
                updatedAt: 100
            ),
        ]),
        2: .success([
            try workflowRun(
                id: 22,
                repository: runningRepository,
                status: .inProgress,
                conclusion: nil,
                updatedAt: 200
            ),
        ]),
        3: .success([
            try workflowRun(
                id: 33,
                repository: excludedRepository,
                status: .completed,
                conclusion: .failure,
                updatedAt: 300
            ),
        ]),
    ])
    let provider = GitHubActivityProvider(workflowRunLoader: loader)
    let profile = try githubProfile(selection: .selected([1, 2]))
    let inventory = try githubInventory(
        repositories: [failedRepository, runningRepository, excludedRepository]
    )

    let result = await provider.load(profile: profile, inventory: inventory)

    #expect(result.items.map(\.repository) == ["acme/api", "acme/web"])
    #expect(result.items.map(\.state) == [.failed, .running])
    #expect(result.failures.isEmpty)
    #expect(Set(await loader.requestedIDs()) == Set([1, 2]))
}

@Test
func deduplicatesRepositoriesAcrossInstallations() async throws {
    let duplicate = try repository(id: 9, fullName: "acme/shared")
    let loader = ActivityLoaderStub(responses: [9: .success([])])
    let provider = GitHubActivityProvider(workflowRunLoader: loader)
    let profile = try githubProfile(selection: .allAccessible)
    let account = GitHubAuthenticatedAccount(
        identity: profile.account
    )
    let inventory = GitHubAccessInventory(
        account: account,
        installations: [
            installationAccess(id: 10, repositories: [duplicate]),
            installationAccess(id: 20, repositories: [duplicate]),
        ]
    )

    _ = await provider.load(profile: profile, inventory: inventory)

    #expect(await loader.requestedIDs() == [9])
}

@Test
func repositoryFailureDoesNotSuppressHealthyRepositoryActivity() async throws {
    let healthyRepository = try repository(id: 1, fullName: "acme/healthy")
    let forbiddenRepository = try repository(id: 2, fullName: "acme/private")
    let loader = ActivityLoaderStub(responses: [
        1: .success([
            try workflowRun(
                id: 100,
                repository: healthyRepository,
                status: .queued,
                conclusion: nil,
                updatedAt: 100
            ),
        ]),
        2: .failure(.forbidden),
    ])
    let provider = GitHubActivityProvider(workflowRunLoader: loader)
    let profile = try githubProfile(selection: .allAccessible)
    let inventory = try githubInventory(
        repositories: [healthyRepository, forbiddenRepository]
    )

    let result = await provider.load(profile: profile, inventory: inventory)

    #expect(result.items.count == 1)
    #expect(result.items[0].repository == "acme/healthy")
    #expect(result.items[0].state == .waiting)
    #expect(
        result.failures == [
            GitHubRepositoryActivityFailure(
                repositoryID: 2,
                repositoryFullName: "acme/private",
                reason: .forbidden
            ),
        ]
    )
}

@Test
func limitsConcurrentRepositoryRequests() async throws {
    let repositories = try (1 ... 8).map {
        try repository(id: Int64($0), fullName: "acme/repo-\($0)")
    }
    let responses = Dictionary(
        uniqueKeysWithValues: repositories.map { ($0.id, .success([])) }
    ) as [Int64: Result<[GitHubWorkflowRun], ActivityLoaderStubError>]
    let loader = ActivityLoaderStub(
        responses: responses,
        delayNanoseconds: 50_000_000
    )
    let provider = GitHubActivityProvider(
        workflowRunLoader: loader,
        maximumConcurrentRepositories: 3
    )
    let profile = try githubProfile(selection: .allAccessible)
    let inventory = try githubInventory(repositories: repositories)

    _ = await provider.load(profile: profile, inventory: inventory)

    #expect(await loader.requestedIDs().count == 8)
    #expect(await loader.maximumConcurrency() <= 3)
    #expect(await loader.maximumConcurrency() > 1)
}

private func githubProfile(
    selection: GitHubRepositoryMonitoringSelection
) throws -> GitHubConnectionProfile {
    GitHubConnectionProfile(
        connection: GitHubConnection(
            id: UUID(uuidString: "40000000-0000-0000-0000-000000000001")!,
            displayName: "GitHub.com",
            deploymentKind: .githubDotCom,
            webBaseURL: try #require(URL(string: "https://github.com"))
        ),
        account: GitHubAccountIdentity(id: "100", login: "octocat"),
        authenticationMethod: .deviceFlow,
        clientID: "Iv1.public-client-id",
        repositorySelection: selection,
        isEnabled: true
    )
}

private func githubInventory(
    repositories: [GitHubRepositoryAccess]
) throws -> GitHubAccessInventory {
    let profile = try githubProfile(selection: .allAccessible)
    return GitHubAccessInventory(
        account: GitHubAuthenticatedAccount(identity: profile.account),
        installations: [
            installationAccess(id: 1, repositories: repositories),
        ]
    )
}

private func installationAccess(
    id: Int64,
    repositories: [GitHubRepositoryAccess]
) -> GitHubInstallationAccess {
    GitHubInstallationAccess(
        installation: GitHubInstallation(
            id: id,
            account: GitHubInstallationAccount(
                id: String(id),
                login: "acme",
                type: "Organization"
            ),
            repositorySelection: "all",
            permissions: ["actions": "read"],
            isSuspended: false
        ),
        repositories: repositories,
        status: .available
    )
}

private func repository(
    id: Int64,
    fullName: String
) throws -> GitHubRepositoryAccess {
    let parts = fullName.split(separator: "/", maxSplits: 1).map(String.init)
    let owner = try #require(parts.first)
    let name = try #require(parts.last)
    return GitHubRepositoryAccess(
        id: id,
        name: name,
        fullName: fullName,
        isPrivate: false,
        webURL: try #require(URL(string: "https://github.com/\(fullName)")),
        ownerLogin: owner,
        permissions: GitHubRepositoryPermissions(pull: true)
    )
}

private func workflowRun(
    id: Int64,
    repository: GitHubRepositoryAccess,
    status: GitHubWorkflowRunStatus,
    conclusion: GitHubWorkflowRunConclusion?,
    updatedAt: TimeInterval
) throws -> GitHubWorkflowRun {
    GitHubWorkflowRun(
        id: id,
        workflowID: 10,
        name: "CI",
        displayTitle: "Build",
        event: "push",
        status: status,
        conclusion: conclusion,
        runNumber: 1,
        headBranch: "main",
        headSHA: "abcdef",
        webURL: try #require(URL(string: "\(repository.webURL.absoluteString)/actions/runs/\(id)")),
        pullRequestNumbers: [],
        createdAt: Date(timeIntervalSince1970: updatedAt - 10),
        updatedAt: Date(timeIntervalSince1970: updatedAt)
    )
}

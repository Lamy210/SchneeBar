import Foundation
import SchneeBarCore
import SchneeBarGitHub
import SchneeBarGitHubActivityProvider
import Testing

private actor RecoverySequenceLoader: GitHubWorkflowRunLoading {
    enum Response: Sendable {
        case runs([GitHubWorkflowRun])
        case timedOut
    }

    private var responses: [Response]
    private let delayNanoseconds: UInt64
    private var callCount = 0

    init(
        _ responses: [Response],
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
        callCount += 1
        if delayNanoseconds > 0 {
            try await Task.sleep(nanoseconds: delayNanoseconds)
        }
        guard !responses.isEmpty else {
            return []
        }
        let response = responses.removeFirst()
        switch response {
        case let .runs(runs):
            return runs
        case .timedOut:
            throw URLError(.timedOut)
        }
    }

    func calls() -> Int {
        callCount
    }
}

@Test
func activityLoadResultRecoveryEventsDefaultToEmpty() {
    let result = GitHubActivityLoadResult(surfaces: [:])
    #expect(result.recoveryEvents.isEmpty)
}

@Test
func activityProviderEmitsFailureToSuccessRecoveryWithoutExtraWorkflowRequests() async throws {
    let repository = try recoveryIntegrationRepository()
    let loader = RecoverySequenceLoader([
        .runs([
            try recoveryIntegrationRun(
                id: 100,
                runNumber: 10,
                conclusion: .failure,
                repository: repository
            ),
        ]),
        .runs([
            try recoveryIntegrationRun(
                id: 101,
                runNumber: 11,
                conclusion: .success,
                repository: repository
            ),
        ]),
        .runs([
            try recoveryIntegrationRun(
                id: 101,
                runNumber: 11,
                conclusion: .success,
                repository: repository
            ),
        ]),
    ])
    let provider = GitHubActivityProvider(
        workflowRunLoader: loader,
        maximumConcurrentRepositories: 1,
        maximumRepositoriesPerRefresh: 1,
        minimumColdRepositoriesPerRefresh: 1
    )
    let profile = try recoveryIntegrationProfile()
    let inventory = try recoveryIntegrationInventory(
        profile: profile,
        repository: repository
    )

    let failed = await provider.load(profile: profile, inventory: inventory)
    let recovered = await provider.load(profile: profile, inventory: inventory)
    let repeated = await provider.load(profile: profile, inventory: inventory)

    #expect(failed.recoveryEvents.isEmpty)
    #expect(failed.items.map(\.state) == [.failed])
    #expect(recovered.recoveryEvents.count == 1)
    #expect(recovered.recoveryEvents[0].repository == "acme/app")
    #expect(recovered.items.isEmpty)
    #expect(repeated.recoveryEvents.isEmpty)
    #expect(await loader.calls() == 3)
}

@Test
func activityProviderRetainsArmedRecoveryAcrossTransientWorkflowFailure() async throws {
    let repository = try recoveryIntegrationRepository()
    let loader = RecoverySequenceLoader([
        .runs([
            try recoveryIntegrationRun(
                id: 100,
                runNumber: 10,
                conclusion: .failure,
                repository: repository
            ),
        ]),
        .timedOut,
        .runs([
            try recoveryIntegrationRun(
                id: 101,
                runNumber: 11,
                conclusion: .success,
                repository: repository
            ),
        ]),
    ])
    let provider = GitHubActivityProvider(
        workflowRunLoader: loader,
        maximumConcurrentRepositories: 1,
        maximumRepositoriesPerRefresh: 1,
        minimumColdRepositoriesPerRefresh: 1
    )
    let profile = try recoveryIntegrationProfile()
    let inventory = try recoveryIntegrationInventory(
        profile: profile,
        repository: repository
    )

    let first = await provider.load(profile: profile, inventory: inventory)
    let outage = await provider.load(profile: profile, inventory: inventory)
    let recovered = await provider.load(profile: profile, inventory: inventory)

    #expect(first.recoveryEvents.isEmpty)
    #expect(outage.recoveryEvents.isEmpty)
    #expect(recovered.recoveryEvents.count == 1)
    #expect(await loader.calls() == 3)
}

@Test
func activityProviderResetClearsRecoveryState() async throws {
    let repository = try recoveryIntegrationRepository()
    let loader = RecoverySequenceLoader([
        .runs([
            try recoveryIntegrationRun(
                id: 100,
                runNumber: 10,
                conclusion: .failure,
                repository: repository
            ),
        ]),
        .runs([
            try recoveryIntegrationRun(
                id: 101,
                runNumber: 11,
                conclusion: .success,
                repository: repository
            ),
        ]),
    ])
    let provider = GitHubActivityProvider(
        workflowRunLoader: loader,
        maximumConcurrentRepositories: 1,
        maximumRepositoriesPerRefresh: 1,
        minimumColdRepositoriesPerRefresh: 1
    )
    let profile = try recoveryIntegrationProfile()
    let inventory = try recoveryIntegrationInventory(
        profile: profile,
        repository: repository
    )

    _ = await provider.load(profile: profile, inventory: inventory)
    await provider.reset(connectionID: profile.id)
    let afterReset = await provider.load(profile: profile, inventory: inventory)

    #expect(afterReset.recoveryEvents.isEmpty)
    #expect(await loader.calls() == 2)
}

@Test
func activityProviderCachedReentrantResultNeverReplaysRecovery() async throws {
    let repository = try recoveryIntegrationRepository()
    let loader = RecoverySequenceLoader(
        [
            .runs([
                try recoveryIntegrationRun(
                    id: 100,
                    runNumber: 10,
                    conclusion: .failure,
                    repository: repository
                ),
            ]),
            .runs([
                try recoveryIntegrationRun(
                    id: 101,
                    runNumber: 11,
                    conclusion: .success,
                    repository: repository
                ),
            ]),
            .runs([
                try recoveryIntegrationRun(
                    id: 101,
                    runNumber: 11,
                    conclusion: .success,
                    repository: repository
                ),
            ]),
        ],
        delayNanoseconds: 50_000_000
    )
    let provider = GitHubActivityProvider(
        workflowRunLoader: loader,
        maximumConcurrentRepositories: 1,
        maximumRepositoriesPerRefresh: 1,
        minimumColdRepositoriesPerRefresh: 1
    )
    let profile = try recoveryIntegrationProfile()
    let inventory = try recoveryIntegrationInventory(
        profile: profile,
        repository: repository
    )

    _ = await provider.load(profile: profile, inventory: inventory)
    let recovered = await provider.load(profile: profile, inventory: inventory)
    #expect(recovered.recoveryEvents.count == 1)

    async let polling = provider.load(profile: profile, inventory: inventory)
    try await Task.sleep(nanoseconds: 5_000_000)
    let cached = await provider.load(profile: profile, inventory: inventory)
    let completed = await polling

    #expect(cached.recoveryEvents.isEmpty)
    #expect(completed.recoveryEvents.isEmpty)
}

@Test
func activityProviderPruningMonitoredRepositoryClearsRecoveryState() async throws {
    let repository = try recoveryIntegrationRepository()
    let loader = RecoverySequenceLoader([
        .runs([
            try recoveryIntegrationRun(
                id: 100,
                runNumber: 10,
                conclusion: .failure,
                repository: repository
            ),
        ]),
        .runs([
            try recoveryIntegrationRun(
                id: 101,
                runNumber: 11,
                conclusion: .success,
                repository: repository
            ),
        ]),
    ])
    let provider = GitHubActivityProvider(
        workflowRunLoader: loader,
        maximumConcurrentRepositories: 1,
        maximumRepositoriesPerRefresh: 1,
        minimumColdRepositoriesPerRefresh: 1
    )
    let profile = try recoveryIntegrationProfile()
    let inventory = try recoveryIntegrationInventory(
        profile: profile,
        repository: repository
    )

    _ = await provider.load(profile: profile, inventory: inventory)

    let unmonitored = GitHubConnectionProfile(
        connection: profile.connection,
        account: profile.account,
        authenticationMethod: profile.authenticationMethod,
        clientID: profile.clientID,
        repositorySelection: .selected([]),
        isEnabled: true,
        createdAt: profile.createdAt,
        lastConnectedAt: profile.lastConnectedAt
    )
    _ = await provider.load(profile: unmonitored, inventory: inventory)

    let afterReenable = await provider.load(
        profile: profile,
        inventory: inventory
    )

    #expect(afterReenable.recoveryEvents.isEmpty)
    #expect(await loader.calls() == 2)
}

private func recoveryIntegrationProfile() throws -> GitHubConnectionProfile {
    GitHubConnectionProfile(
        connection: GitHubConnection(
            id: UUID(uuidString: "50000000-0000-0000-0000-000000000001")!,
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

private func recoveryIntegrationRepository() throws -> GitHubRepositoryAccess {
    GitHubRepositoryAccess(
        id: 42,
        name: "app",
        fullName: "acme/app",
        isPrivate: true,
        webURL: try #require(URL(string: "https://github.com/acme/app")),
        ownerLogin: "acme",
        permissions: GitHubRepositoryPermissions(pull: true),
        defaultBranch: "main"
    )
}

private func recoveryIntegrationInventory(
    profile: GitHubConnectionProfile,
    repository: GitHubRepositoryAccess
) -> GitHubAccessInventory {
    GitHubAccessInventory(
        account: GitHubAuthenticatedAccount(identity: profile.account),
        installations: [
            GitHubInstallationAccess(
                installation: GitHubInstallation(
                    id: 1,
                    account: GitHubInstallationAccount(
                        id: "1",
                        login: "acme",
                        type: "Organization"
                    ),
                    repositorySelection: "all",
                    permissions: ["actions": "read"],
                    isSuspended: false
                ),
                repositories: [repository],
                status: .available
            ),
        ]
    )
}

private func recoveryIntegrationRun(
    id: Int64,
    runNumber: Int,
    conclusion: GitHubWorkflowRunConclusion,
    repository: GitHubRepositoryAccess
) throws -> GitHubWorkflowRun {
    GitHubWorkflowRun(
        id: id,
        workflowID: 41,
        name: "CI",
        displayTitle: "Build",
        event: "pull_request",
        status: .completed,
        conclusion: conclusion,
        runNumber: runNumber,
        headBranch: "feature",
        headSHA: "sha-\(id)",
        webURL: try #require(
            URL(string: "\(repository.webURL.absoluteString)/actions/runs/\(id)")
        ),
        pullRequestNumbers: [120],
        createdAt: Date(timeIntervalSince1970: TimeInterval(runNumber * 10 - 5)),
        updatedAt: Date(timeIntervalSince1970: TimeInterval(runNumber * 10))
    )
}

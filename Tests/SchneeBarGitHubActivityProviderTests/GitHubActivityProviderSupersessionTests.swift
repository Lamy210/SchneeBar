import Foundation
import SchneeBarCore
import SchneeBarGitHub
import SchneeBarGitHubActivityProvider
import Testing

private actor SupersessionWorkflowLoader: GitHubWorkflowRunLoading {
    private let runs: [GitHubWorkflowRun]

    init(runs: [GitHubWorkflowRun]) {
        self.runs = runs
    }

    func workflowRuns(
        connection: GitHubConnection,
        identity: GitHubAccountIdentity,
        clientID: String?,
        repository: GitHubRepositoryAccess,
        query: GitHubWorkflowRunQuery
    ) async throws -> [GitHubWorkflowRun] {
        runs
    }
}

@Test
func suppressesSupersededPullRequestWorkflowActivity() async throws {
    let repository = try supersessionRepository()
    let loader = SupersessionWorkflowLoader(runs: [
        try supersessionProviderRun(
            id: 80,
            repository: repository,
            status: .completed,
            conclusion: .failure,
            runNumber: 80,
            headSHA: "aaa",
            updatedAt: 100
        ),
        try supersessionProviderRun(
            id: 81,
            repository: repository,
            status: .inProgress,
            conclusion: nil,
            runNumber: 81,
            headSHA: "bbb",
            updatedAt: 200
        ),
    ])
    let provider = GitHubActivityProvider(workflowRunLoader: loader)

    let result = await provider.load(
        profile: try supersessionProfile(),
        inventory: try supersessionInventory(repository: repository)
    )

    #expect(result.items.map(\.id) == ["github-actions:1:81"])
    #expect(result.items.map(\.state) == [.running])
}

@Test
func successfulReplacementCanLeaveWorkflowInboxEmpty() async throws {
    let repository = try supersessionRepository()
    let loader = SupersessionWorkflowLoader(runs: [
        try supersessionProviderRun(
            id: 80,
            repository: repository,
            status: .completed,
            conclusion: .failure,
            runNumber: 80,
            headSHA: "aaa",
            updatedAt: 100
        ),
        try supersessionProviderRun(
            id: 81,
            repository: repository,
            status: .completed,
            conclusion: .success,
            runNumber: 81,
            headSHA: "bbb",
            updatedAt: 200
        ),
    ])
    let provider = GitHubActivityProvider(workflowRunLoader: loader)

    let result = await provider.load(
        profile: try supersessionProfile(),
        inventory: try supersessionInventory(repository: repository)
    )

    #expect(result.surface(.workflows).items.isEmpty)
}

private func supersessionProfile() throws -> GitHubConnectionProfile {
    GitHubConnectionProfile(
        connection: GitHubConnection(
            id: UUID(uuidString: "64000000-0000-0000-0000-000000000001")!,
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

private func supersessionRepository() throws -> GitHubRepositoryAccess {
    GitHubRepositoryAccess(
        id: 1,
        name: "api",
        fullName: "acme/api",
        isPrivate: false,
        webURL: try #require(URL(string: "https://github.com/acme/api")),
        ownerLogin: "acme",
        permissions: GitHubRepositoryPermissions(pull: true)
    )
}

private func supersessionInventory(
    repository: GitHubRepositoryAccess
) throws -> GitHubAccessInventory {
    let profile = try supersessionProfile()
    return GitHubAccessInventory(
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

private func supersessionProviderRun(
    id: Int64,
    repository: GitHubRepositoryAccess,
    status: GitHubWorkflowRunStatus,
    conclusion: GitHubWorkflowRunConclusion?,
    runNumber: Int,
    headSHA: String,
    updatedAt: TimeInterval
) throws -> GitHubWorkflowRun {
    GitHubWorkflowRun(
        id: id,
        workflowID: 10,
        name: "CI",
        displayTitle: "Build",
        event: "pull_request",
        status: status,
        conclusion: conclusion,
        runNumber: runNumber,
        headBranch: "feature",
        headSHA: headSHA,
        webURL: try #require(URL(string: "\(repository.webURL.absoluteString)/actions/runs/\(id)")),
        pullRequestNumbers: [120],
        createdAt: Date(timeIntervalSince1970: updatedAt - 10),
        updatedAt: Date(timeIntervalSince1970: updatedAt)
    )
}

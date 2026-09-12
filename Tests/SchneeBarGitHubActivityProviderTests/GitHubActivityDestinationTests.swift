import Foundation
import SchneeBarGitHub
import SchneeBarGitHubActivityProvider
import Testing

private struct DestinationRunLoader: GitHubWorkflowRunLoading {
    let run: GitHubWorkflowRun

    func workflowRuns(
        connection: GitHubConnection,
        identity: GitHubAccountIdentity,
        clientID: String?,
        repository: GitHubRepositoryAccess,
        query: GitHubWorkflowRunQuery
    ) async throws -> [GitHubWorkflowRun] {
        [run]
    }
}

@Test
func activityItemKeepsTrustedWorkflowRunDestination() async throws {
    let repository = GitHubRepositoryAccess(
        id: 42,
        name: "SchneeBar",
        fullName: "Lamy210/SchneeBar",
        isPrivate: false,
        webURL: try #require(URL(string: "https://github.com/Lamy210/SchneeBar")),
        ownerLogin: "Lamy210",
        permissions: GitHubRepositoryPermissions(pull: true)
    )
    let destination = try #require(
        URL(string: "https://github.com/Lamy210/SchneeBar/actions/runs/12345")
    )
    let run = GitHubWorkflowRun(
        id: 12_345,
        workflowID: 90,
        name: "CI",
        displayTitle: "macOS Tests",
        event: "push",
        status: .completed,
        conclusion: .failure,
        runNumber: 31,
        headBranch: "main",
        headSHA: "abcdef",
        webURL: destination,
        pullRequestNumbers: [],
        createdAt: Date(timeIntervalSince1970: 1_000),
        updatedAt: Date(timeIntervalSince1970: 1_100)
    )
    let profile = GitHubConnectionProfile(
        connection: GitHubConnection(
            id: UUID(uuidString: "50000000-0000-0000-0000-000000000001")!,
            displayName: "GitHub.com",
            deploymentKind: .githubDotCom,
            webBaseURL: try #require(URL(string: "https://github.com"))
        ),
        account: GitHubAccountIdentity(id: "100", login: "Lamy210"),
        authenticationMethod: .deviceFlow,
        clientID: "Iv1.public-client-id",
        repositorySelection: .allAccessible,
        isEnabled: true
    )
    let inventory = GitHubAccessInventory(
        account: GitHubAuthenticatedAccount(identity: profile.account),
        installations: [
            GitHubInstallationAccess(
                installation: GitHubInstallation(
                    id: 1,
                    account: GitHubInstallationAccount(
                        id: "1",
                        login: "Lamy210",
                        type: "User"
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

    let provider = GitHubActivityProvider(
        workflowRunLoader: DestinationRunLoader(run: run),
        maximumRepositoriesPerRefresh: 1
    )
    let result = await provider.load(profile: profile, inventory: inventory)

    let item = try #require(result.items.first)
    #expect(item.destinationURL == destination)
    #expect(item.state == .failed)
}

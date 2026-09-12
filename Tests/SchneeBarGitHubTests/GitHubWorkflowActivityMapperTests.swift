import Foundation
import SchneeBarGitHub
import Testing

@Test
func classifiesWorkflowStatesWithoutTreatingCancellationAsFailure() throws {
    let mapper = GitHubWorkflowActivityMapper()
    let repository = try mapperRepository()

    #expect(mapper.classification(for: try mapperRun(status: .queued)) == .waiting)
    #expect(mapper.classification(for: try mapperRun(status: .inProgress)) == .running)
    #expect(
        mapper.classification(
            for: try mapperRun(status: .completed, conclusion: .success)
        ) == .success
    )
    #expect(
        mapper.classification(
            for: try mapperRun(status: .completed, conclusion: .failure)
        ) == .failed
    )
    #expect(
        mapper.classification(
            for: try mapperRun(status: .completed, conclusion: .timedOut)
        ) == .failed
    )
    #expect(
        mapper.classification(
            for: try mapperRun(status: .completed, conclusion: .cancelled)
        ) == .ignored
    )
    #expect(
        mapper.classification(
            for: try mapperRun(status: .completed, conclusion: .skipped)
        ) == .ignored
    )

    let cancelled = mapper.map(
        run: try mapperRun(status: .completed, conclusion: .cancelled),
        repository: repository
    )
    #expect(cancelled.classification == .ignored)
    #expect(cancelled.detail.hasPrefix("Completed"))
}

@Test
func mapsPullRequestAndBranchContext() throws {
    let mapper = GitHubWorkflowActivityMapper()
    let repository = try mapperRepository()

    let pullRequestActivity = mapper.map(
        run: try mapperRun(
            status: .inProgress,
            pullRequestNumbers: [42],
            branch: "feature/auth"
        ),
        repository: repository
    )
    #expect(pullRequestActivity.context == "PR #42 · CI")
    #expect(pullRequestActivity.repositoryFullName == "octocat/project")
    #expect(pullRequestActivity.id == "github-actions:42:100")

    let branchActivity = mapper.map(
        run: try mapperRun(
            id: 101,
            status: .queued,
            pullRequestNumbers: [],
            branch: "main"
        ),
        repository: repository
    )
    #expect(branchActivity.context == "main · CI")
}

@Test
func hidesSuccessAndIgnoredByDefault() throws {
    let mapper = GitHubWorkflowActivityMapper()
    let repository = try mapperRepository()
    let runs = [
        try mapperRun(id: 1, status: .completed, conclusion: .success),
        try mapperRun(id: 2, status: .completed, conclusion: .cancelled),
        try mapperRun(id: 3, status: .inProgress),
        try mapperRun(id: 4, status: .completed, conclusion: .failure),
    ]

    let visible = mapper.visibleActivities(runs: runs, repository: repository)

    #expect(visible.map(\.workflowRunID) == [4, 3])
}

@Test
func includesSuccessWhenRequestedAndSortsByPriorityThenRecency() throws {
    let mapper = GitHubWorkflowActivityMapper()
    let repository = try mapperRepository()
    let runs = [
        try mapperRun(
            id: 1,
            status: .queued,
            updatedAt: Date(timeIntervalSince1970: 100)
        ),
        try mapperRun(
            id: 2,
            status: .completed,
            conclusion: .failure,
            updatedAt: Date(timeIntervalSince1970: 50)
        ),
        try mapperRun(
            id: 3,
            status: .inProgress,
            updatedAt: Date(timeIntervalSince1970: 200)
        ),
        try mapperRun(
            id: 4,
            status: .completed,
            conclusion: .success,
            updatedAt: Date(timeIntervalSince1970: 300)
        ),
    ]

    let visible = mapper.visibleActivities(
        runs: runs,
        repository: repository,
        includeSuccessful: true
    )

    #expect(visible.map(\.workflowRunID) == [2, 3, 1, 4])
}

@Test
func futureUnknownStateIsKeptAsWaitingInsteadOfInventingFailure() throws {
    let mapper = GitHubWorkflowActivityMapper()
    let run = try mapperRun(
        status: .unknown("future_state"),
        conclusion: .unknown("future_conclusion")
    )

    #expect(mapper.classification(for: run) == .waiting)
}

private func mapperRun(
    id: Int64 = 100,
    status: GitHubWorkflowRunStatus,
    conclusion: GitHubWorkflowRunConclusion? = nil,
    pullRequestNumbers: [Int] = [],
    branch: String? = "main",
    updatedAt: Date = Date(timeIntervalSince1970: 200)
) throws -> GitHubWorkflowRun {
    GitHubWorkflowRun(
        id: id,
        workflowID: 9,
        name: "CI",
        displayTitle: "Build and test",
        event: pullRequestNumbers.isEmpty ? "push" : "pull_request",
        status: status,
        conclusion: conclusion,
        runNumber: 7,
        headBranch: branch,
        headSHA: "abcdef123456",
        webURL: try #require(URL(string: "https://github.com/octocat/project/actions/runs/\(id)")),
        pullRequestNumbers: pullRequestNumbers,
        createdAt: Date(timeIntervalSince1970: 100),
        updatedAt: updatedAt
    )
}

private func mapperRepository() throws -> GitHubRepositoryAccess {
    GitHubRepositoryAccess(
        id: 42,
        name: "project",
        fullName: "octocat/project",
        isPrivate: false,
        webURL: try #require(URL(string: "https://github.com/octocat/project")),
        ownerLogin: "octocat",
        permissions: GitHubRepositoryPermissions(pull: true)
    )
}

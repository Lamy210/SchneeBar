import Foundation
import SchneeBarGitHub
import Testing

@Test
func correlationTreatsSameRunAsExact() throws {
    let run = try correlationRun(
        id: 10,
        event: "push",
        headBranch: "main",
        headSHA: "abc123"
    )

    let result = GitHubWorkflowExecutionCorrelator().correlate(
        repositoryID: 42,
        left: run,
        right: run
    )

    #expect(result.confidence == .exact)
    #expect(result.reason == .sameRun)
}

@Test
func correlationUsesSharedPullRequestBeforeCommitSHA() throws {
    let left = try correlationRun(
        id: 11,
        event: "pull_request",
        headBranch: "feature/a",
        headSHA: "pr-merge-sha",
        pullRequestNumbers: [25]
    )
    let right = try correlationRun(
        id: 12,
        event: "pull_request",
        headBranch: "feature/a",
        headSHA: "different-sha",
        pullRequestNumbers: [30, 25]
    )

    let result = GitHubWorkflowExecutionCorrelator().correlate(
        repositoryID: 42,
        left: left,
        right: right
    )

    #expect(result.confidence == .exact)
    #expect(result.reason == .sharedPullRequest(25))
}

@Test
func correlationUsesSharedCommitAsHighConfidence() throws {
    let left = try correlationRun(
        id: 13,
        event: "push",
        headBranch: "main",
        headSHA: "ABCDEF"
    )
    let right = try correlationRun(
        id: 14,
        event: "workflow_dispatch",
        headBranch: "main",
        headSHA: "abcdef"
    )

    let result = GitHubWorkflowExecutionCorrelator().correlate(
        repositoryID: 42,
        left: left,
        right: right
    )

    #expect(result.confidence == .high)
    #expect(result.reason == .sharedHeadCommit("abcdef"))
}

@Test
func correlationDoesNotGuessFromBranchAndTime() throws {
    let left = try correlationRun(
        id: 15,
        event: "push",
        headBranch: "main",
        headSHA: "commit-a",
        updatedAt: 100
    )
    let right = try correlationRun(
        id: 16,
        event: "push",
        headBranch: "main",
        headSHA: "commit-b",
        updatedAt: 101
    )

    let result = GitHubWorkflowExecutionCorrelator().correlate(
        repositoryID: 42,
        left: left,
        right: right
    )

    #expect(result.confidence == .unknown)
    #expect(result.reason == .noReliableEvidence)
}

@Test
func correlationDoesNotJoinPullRequestAndMainAfterSHAChangesWithoutEvidence() throws {
    let pullRequest = try correlationRun(
        id: 17,
        event: "pull_request",
        headBranch: "feature/a",
        headSHA: "synthetic-pr-merge",
        pullRequestNumbers: [25]
    )
    let main = try correlationRun(
        id: 18,
        event: "push",
        headBranch: "main",
        headSHA: "squash-merge-commit"
    )

    let result = GitHubWorkflowExecutionCorrelator().correlate(
        repositoryID: 42,
        left: pullRequest,
        right: main
    )

    #expect(result.confidence == .unknown)
    #expect(result.reason == .noReliableEvidence)
}

@Test
func bestMatchPrefersExactCorrelationOverNewerHighCorrelation() throws {
    let target = try correlationRun(
        id: 20,
        event: "pull_request",
        headBranch: "feature/a",
        headSHA: "target-sha",
        pullRequestNumbers: [25],
        updatedAt: 100
    )
    let high = try correlationRun(
        id: 21,
        event: "workflow_dispatch",
        headBranch: "feature/a",
        headSHA: "target-sha",
        updatedAt: 300
    )
    let exact = try correlationRun(
        id: 22,
        event: "pull_request",
        headBranch: "feature/a",
        headSHA: "another-sha",
        pullRequestNumbers: [25],
        updatedAt: 200
    )

    let match = GitHubWorkflowExecutionCorrelator().bestMatch(
        repositoryID: 42,
        for: target,
        among: [high, exact]
    )

    #expect(match?.id == exact.id)
}

private func correlationRun(
    id: Int64,
    event: String,
    headBranch: String?,
    headSHA: String,
    pullRequestNumbers: [Int] = [],
    updatedAt: TimeInterval = 0
) throws -> GitHubWorkflowRun {
    GitHubWorkflowRun(
        id: id,
        workflowID: 100,
        name: "CI",
        displayTitle: "CI",
        event: event,
        status: .completed,
        conclusion: .success,
        runNumber: Int(id),
        headBranch: headBranch,
        headSHA: headSHA,
        webURL: try #require(
            URL(string: "https://github.com/octocat/project/actions/runs/\(id)")
        ),
        pullRequestNumbers: pullRequestNumbers,
        createdAt: Date(timeIntervalSince1970: updatedAt),
        updatedAt: Date(timeIntervalSince1970: updatedAt)
    )
}

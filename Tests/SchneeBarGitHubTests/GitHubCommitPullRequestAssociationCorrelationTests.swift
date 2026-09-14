import Foundation
import SchneeBarGitHub
import Testing

@Test
func baseCommitPullRequestAssociationProvidesExactMergedCorrelation() throws {
    let metadata = try associationMetadata()
    let pullRequestRun = try associationRun(
        id: 120,
        event: "pull_request",
        branch: "feature/jobs",
        headSHA: "final-head",
        pullRequestNumbers: [25]
    )
    let baseRun = try associationRun(
        id: 121,
        event: "push",
        branch: "main",
        headSHA: "LANDED-COMMIT"
    )

    let result = GitHubWorkflowExecutionCorrelator().correlateMergedPullRequest(
        repositoryID: 42,
        pullRequest: metadata,
        pullRequestRun: pullRequestRun,
        baseRun: baseRun,
        baseCommitPullRequestNumbers: [25]
    )

    #expect(result.confidence == .exact)
    #expect(result.reason == .mergedPullRequest(25, "landed-commit"))
}

@Test
func commitAssociationDoesNotPromoteRunFromDifferentBaseBranch() throws {
    let metadata = try associationMetadata()
    let pullRequestRun = try associationRun(
        id: 122,
        event: "pull_request",
        branch: "feature/jobs",
        headSHA: "final-head",
        pullRequestNumbers: [25]
    )
    let differentBranchRun = try associationRun(
        id: 123,
        event: "push",
        branch: "release",
        headSHA: "landed-commit"
    )

    let result = GitHubWorkflowExecutionCorrelator().correlateMergedPullRequest(
        repositoryID: 42,
        pullRequest: metadata,
        pullRequestRun: pullRequestRun,
        baseRun: differentBranchRun,
        baseCommitPullRequestNumbers: [25]
    )

    #expect(result.confidence == .unknown)
    #expect(result.reason == .noReliableEvidence)
}

private func associationMetadata() throws -> GitHubPullRequestMetadata {
    GitHubPullRequestMetadata(
        number: 25,
        state: .closed,
        isDraft: false,
        isMerged: true,
        headRef: "feature/jobs",
        headSHA: "final-head",
        baseRef: "main",
        baseSHA: "base-before-merge",
        mergeCommitSHA: nil,
        webURL: try #require(URL(string: "https://github.com/octocat/project/pull/25")),
        updatedAt: Date(timeIntervalSince1970: 100),
        mergedAt: Date(timeIntervalSince1970: 90)
    )
}

private func associationRun(
    id: Int64,
    event: String,
    branch: String?,
    headSHA: String,
    pullRequestNumbers: [Int] = []
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
        headBranch: branch,
        headSHA: headSHA,
        webURL: try #require(URL(string: "https://github.com/octocat/project/actions/runs/\(id)")),
        pullRequestNumbers: pullRequestNumbers,
        createdAt: Date(timeIntervalSince1970: 100),
        updatedAt: Date(timeIntervalSince1970: 100)
    )
}

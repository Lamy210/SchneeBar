import Foundation
import SchneeBarGitHub
import Testing

@Test
func mergedPullRequestCommitProvidesExactCorrelation() throws {
    let metadata = try mergedCorrelationMetadata(
        number: 25,
        isMerged: true,
        headSHA: "HEAD-FINAL",
        mergeCommitSHA: "squash-main"
    )
    let pullRequestRun = try mergedCorrelationRun(
        id: 100,
        event: "pull_request",
        branch: "feature/jobs",
        headSHA: " head-final ",
        pullRequestNumbers: [25]
    )
    let baseRun = try mergedCorrelationRun(
        id: 101,
        event: "push",
        branch: "main",
        headSHA: "SQUASH-MAIN"
    )

    let result = GitHubWorkflowExecutionCorrelator().correlateMergedPullRequest(
        repositoryID: 42,
        pullRequest: metadata,
        pullRequestRun: pullRequestRun,
        baseRun: baseRun
    )

    #expect(result.confidence == .exact)
    #expect(result.reason == .mergedPullRequest(25, "squash-main"))
}

@Test
func mergedMetadataPromotesSharedCommitEvidenceFromHighToExact() throws {
    let metadata = try mergedCorrelationMetadata(
        number: 25,
        isMerged: true,
        headSHA: "same-commit",
        mergeCommitSHA: "same-commit"
    )
    let pullRequestRun = try mergedCorrelationRun(
        id: 110,
        event: "pull_request",
        branch: "feature/jobs",
        headSHA: "same-commit",
        pullRequestNumbers: [25]
    )
    let baseRun = try mergedCorrelationRun(
        id: 111,
        event: "push",
        branch: "main",
        headSHA: "same-commit"
    )

    let direct = GitHubWorkflowExecutionCorrelator().correlate(
        repositoryID: 42,
        left: pullRequestRun,
        right: baseRun
    )
    #expect(direct.confidence == .high)

    let result = GitHubWorkflowExecutionCorrelator().correlateMergedPullRequest(
        repositoryID: 42,
        pullRequest: metadata,
        pullRequestRun: pullRequestRun,
        baseRun: baseRun
    )

    #expect(result.confidence == .exact)
    #expect(result.reason == .mergedPullRequest(25, "same-commit"))
}

@Test
func mergedPullRequestCorrelationRejectsSupersededPullRequestRun() throws {
    let metadata = try mergedCorrelationMetadata(
        number: 25,
        isMerged: true,
        headSHA: "final-head",
        mergeCommitSHA: "main-commit"
    )
    let stalePullRequestRun = try mergedCorrelationRun(
        id: 102,
        event: "pull_request",
        branch: "feature/jobs",
        headSHA: "older-head",
        pullRequestNumbers: [25]
    )
    let baseRun = try mergedCorrelationRun(
        id: 103,
        event: "push",
        branch: "main",
        headSHA: "main-commit"
    )

    let result = GitHubWorkflowExecutionCorrelator().correlateMergedPullRequest(
        repositoryID: 42,
        pullRequest: metadata,
        pullRequestRun: stalePullRequestRun,
        baseRun: baseRun
    )

    #expect(result.confidence == .unknown)
    #expect(result.reason == .noReliableEvidence)
}

@Test
func mergedPullRequestCorrelationRejectsUnmergedMetadata() throws {
    let metadata = try mergedCorrelationMetadata(
        number: 25,
        isMerged: false,
        headSHA: "final-head",
        mergeCommitSHA: "test-merge-commit"
    )
    let pullRequestRun = try mergedCorrelationRun(
        id: 104,
        event: "pull_request",
        branch: "feature/jobs",
        headSHA: "final-head",
        pullRequestNumbers: [25]
    )
    let baseRun = try mergedCorrelationRun(
        id: 105,
        event: "push",
        branch: "main",
        headSHA: "test-merge-commit"
    )

    let result = GitHubWorkflowExecutionCorrelator().correlateMergedPullRequest(
        repositoryID: 42,
        pullRequest: metadata,
        pullRequestRun: pullRequestRun,
        baseRun: baseRun
    )

    #expect(result.confidence == .unknown)
    #expect(result.reason == .noReliableEvidence)
}

@Test
func mergedPullRequestCorrelationRequiresMergedTimestamp() throws {
    let metadata = GitHubPullRequestMetadata(
        number: 25,
        state: .closed,
        isDraft: false,
        isMerged: true,
        headRef: "feature/jobs",
        headSHA: "final-head",
        baseRef: "main",
        baseSHA: "base-before-merge",
        mergeCommitSHA: "main-commit",
        webURL: try #require(URL(string: "https://github.com/octocat/project/pull/25")),
        updatedAt: Date(timeIntervalSince1970: 100),
        mergedAt: nil
    )
    let pullRequestRun = try mergedCorrelationRun(
        id: 112,
        event: "pull_request",
        branch: "feature/jobs",
        headSHA: "final-head",
        pullRequestNumbers: [25]
    )
    let baseRun = try mergedCorrelationRun(
        id: 113,
        event: "push",
        branch: "main",
        headSHA: "main-commit"
    )

    let result = GitHubWorkflowExecutionCorrelator().correlateMergedPullRequest(
        repositoryID: 42,
        pullRequest: metadata,
        pullRequestRun: pullRequestRun,
        baseRun: baseRun
    )

    #expect(result.confidence == .unknown)
    #expect(result.reason == .noReliableEvidence)
}

@Test
func mergedPullRequestCorrelationRequiresMatchingPullRequestNumber() throws {
    let metadata = try mergedCorrelationMetadata(
        number: 25,
        isMerged: true,
        headSHA: "final-head",
        mergeCommitSHA: "main-commit"
    )
    let pullRequestRun = try mergedCorrelationRun(
        id: 106,
        event: "pull_request",
        branch: "feature/jobs",
        headSHA: "final-head",
        pullRequestNumbers: [26]
    )
    let baseRun = try mergedCorrelationRun(
        id: 107,
        event: "push",
        branch: "main",
        headSHA: "main-commit"
    )

    let result = GitHubWorkflowExecutionCorrelator().correlateMergedPullRequest(
        repositoryID: 42,
        pullRequest: metadata,
        pullRequestRun: pullRequestRun,
        baseRun: baseRun
    )

    #expect(result.confidence == .unknown)
    #expect(result.reason == .noReliableEvidence)
}

@Test
func mergedPullRequestCorrelationRequiresLandedCommit() throws {
    let metadata = try mergedCorrelationMetadata(
        number: 25,
        isMerged: true,
        headSHA: "final-head",
        mergeCommitSHA: "landed-commit"
    )
    let pullRequestRun = try mergedCorrelationRun(
        id: 108,
        event: "pull_request",
        branch: "feature/jobs",
        headSHA: "final-head",
        pullRequestNumbers: [25]
    )
    let unrelatedBaseRun = try mergedCorrelationRun(
        id: 109,
        event: "push",
        branch: "main",
        headSHA: "different-main-commit"
    )

    let result = GitHubWorkflowExecutionCorrelator().correlateMergedPullRequest(
        repositoryID: 42,
        pullRequest: metadata,
        pullRequestRun: pullRequestRun,
        baseRun: unrelatedBaseRun
    )

    #expect(result.confidence == .unknown)
    #expect(result.reason == .noReliableEvidence)
}

private func mergedCorrelationMetadata(
    number: Int,
    isMerged: Bool,
    headSHA: String,
    mergeCommitSHA: String?
) throws -> GitHubPullRequestMetadata {
    GitHubPullRequestMetadata(
        number: number,
        state: isMerged ? .closed : .open,
        isDraft: false,
        isMerged: isMerged,
        headRef: "feature/jobs",
        headSHA: headSHA,
        baseRef: "main",
        baseSHA: "base-before-merge",
        mergeCommitSHA: mergeCommitSHA,
        webURL: try #require(URL(string: "https://github.com/octocat/project/pull/\(number)")),
        updatedAt: Date(timeIntervalSince1970: 100),
        mergedAt: isMerged ? Date(timeIntervalSince1970: 90) : nil
    )
}

private func mergedCorrelationRun(
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

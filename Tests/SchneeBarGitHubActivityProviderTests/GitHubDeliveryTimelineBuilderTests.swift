import Foundation
import SchneeBarCore
import SchneeBarGitHub
import SchneeBarGitHubActivityProvider
import Testing

@Test
func deliveryTimelineBuilderBuildsExactPullRequestMergeAndBaseExecution() throws {
    let evidence = try deliveryEvidence(
        baseRuns: [deliveryRun(id: 801, branch: "main", headSHA: "landed-sha")],
        associations: [801: [47]]
    )

    let snapshot = GitHubDeliveryTimelineBuilder().build(
        repositoryID: 42,
        evidence: evidence
    )

    #expect(snapshot.status == .correlated)
    #expect(snapshot.confidence == .exact)
    #expect(snapshot.events.map(\.kind) == [.pullRequest, .merge, .execution])
    #expect(snapshot.events[0].title == "PR #47 workflow")
    #expect(snapshot.events[0].detail == "feature/timeline → main")
    #expect(snapshot.events[0].destinationURL == evidence.selectedRun.webURL)
    #expect(snapshot.events[1].title == "Merged")
    #expect(snapshot.events[1].detail == "into main")
    #expect(snapshot.events[1].occurredAt == evidence.pullRequest?.mergedAt)
    #expect(snapshot.events[2].title == "Base branch · CI")
    #expect(snapshot.events[2].detail == "Succeeded")
    #expect(snapshot.events[2].destinationURL == evidence.baseRuns[0].webURL)
}

@Test
func deliveryTimelineBuilderRejectsWrongPullRequestAssociation() throws {
    let evidence = try deliveryEvidence(
        baseRuns: [deliveryRun(id: 801, branch: "main", headSHA: "landed-sha")],
        associations: [801: [99]]
    )

    let snapshot = GitHubDeliveryTimelineBuilder().build(repositoryID: 42, evidence: evidence)

    #expect(snapshot.status == .evidenceUnavailable)
    #expect(snapshot.confidence == .unknown)
    #expect(snapshot.events.isEmpty)
}

@Test
func deliveryTimelineBuilderRejectsWrongBaseBranch() throws {
    let evidence = try deliveryEvidence(
        baseRuns: [deliveryRun(id: 801, branch: "release", headSHA: "landed-sha")],
        associations: [801: [47]]
    )

    let snapshot = GitHubDeliveryTimelineBuilder().build(repositoryID: 42, evidence: evidence)

    #expect(snapshot.status == .evidenceUnavailable)
}

@Test
func deliveryTimelineBuilderRejectsUnmergedOrMissingMergeTimestamp() throws {
    let unmerged = try deliveryEvidence(
        pullRequest: deliveryPullRequest(isMerged: false, mergedAt: nil),
        baseRuns: [deliveryRun(id: 801, branch: "main", headSHA: "landed-sha")],
        associations: [801: [47]]
    )
    let malformedMerged = try deliveryEvidence(
        pullRequest: deliveryPullRequest(isMerged: true, mergedAt: nil),
        baseRuns: [deliveryRun(id: 801, branch: "main", headSHA: "landed-sha")],
        associations: [801: [47]]
    )

    #expect(GitHubDeliveryTimelineBuilder().build(repositoryID: 42, evidence: unmerged).status == .evidenceUnavailable)
    #expect(GitHubDeliveryTimelineBuilder().build(repositoryID: 42, evidence: malformedMerged).status == .evidenceUnavailable)
}

@Test
func deliveryTimelineBuilderRejectsMissingOrAmbiguousSelectedPullRequestIdentity() throws {
    let missing = GitHubDeliveryTimelineEvidence(
        selectedRun: deliveryRun(id: 700, branch: "feature/timeline", headSHA: "final-head", pullRequestNumbers: []),
        pullRequest: nil,
        baseRuns: [],
        associatedPullRequestNumbersByRunID: [:]
    )
    let ambiguous = GitHubDeliveryTimelineEvidence(
        selectedRun: deliveryRun(id: 700, branch: "feature/timeline", headSHA: "final-head", pullRequestNumbers: [47, 48]),
        pullRequest: try deliveryPullRequest(),
        baseRuns: [deliveryRun(id: 801, branch: "main", headSHA: "landed-sha")],
        associatedPullRequestNumbersByRunID: [801: [47]]
    )

    #expect(GitHubDeliveryTimelineBuilder().build(repositoryID: 42, evidence: missing).status == .evidenceUnavailable)
    #expect(GitHubDeliveryTimelineBuilder().build(repositoryID: 42, evidence: ambiguous).status == .evidenceUnavailable)
}

@Test
func deliveryTimelineBuilderAllowsDifferentWorkflowWhenAssociationProvesPullRequest() throws {
    let differentWorkflow = deliveryRun(
        id: 801,
        workflowID: 999,
        name: "Deploy verification",
        branch: "main",
        headSHA: "landed-sha"
    )
    let evidence = try deliveryEvidence(
        baseRuns: [differentWorkflow],
        associations: [801: [47]]
    )

    let snapshot = GitHubDeliveryTimelineBuilder().build(repositoryID: 42, evidence: evidence)

    #expect(snapshot.status == .correlated)
    #expect(snapshot.confidence == .exact)
    #expect(snapshot.events.last?.title == "Base branch · Deploy verification")
}

@Test
func deliveryTimelineBuilderNeverPromotesBranchTimeOrNameSimilarityWithoutAssociation() throws {
    let candidate = deliveryRun(
        id: 801,
        workflowID: 88,
        name: "CI",
        branch: "main",
        headSHA: "landed-sha",
        updatedAt: Date(timeIntervalSince1970: 301)
    )
    let evidence = try deliveryEvidence(
        baseRuns: [candidate],
        associations: [:]
    )

    let snapshot = GitHubDeliveryTimelineBuilder().build(repositoryID: 42, evidence: evidence)

    #expect(snapshot.status == .evidenceUnavailable)
    #expect(snapshot.confidence == .unknown)
}

@Test
func deliveryTimelineBuilderUsesDeterministicCandidateOrdering() throws {
    let olderSameWorkflow = deliveryRun(
        id: 801,
        workflowID: 88,
        name: "CI",
        branch: "main",
        headSHA: "older-landed",
        updatedAt: Date(timeIntervalSince1970: 200)
    )
    let newerSameWorkflow = deliveryRun(
        id: 802,
        workflowID: 88,
        name: "CI",
        branch: "main",
        headSHA: "newer-landed",
        updatedAt: Date(timeIntervalSince1970: 300)
    )
    let newestDifferentWorkflow = deliveryRun(
        id: 803,
        workflowID: 999,
        name: "Other",
        branch: "main",
        headSHA: "other-landed",
        updatedAt: Date(timeIntervalSince1970: 400)
    )
    let evidence = try deliveryEvidence(
        baseRuns: [newestDifferentWorkflow, olderSameWorkflow, newerSameWorkflow],
        associations: [801: [47], 802: [47], 803: [47]]
    )

    let snapshot = GitHubDeliveryTimelineBuilder().build(repositoryID: 42, evidence: evidence)

    #expect(snapshot.status == .correlated)
    #expect(snapshot.events.last?.id == "github-delivery-execution:802")
}

private func deliveryEvidence(
    pullRequest: GitHubPullRequestMetadata? = nil,
    baseRuns: [GitHubWorkflowRun],
    associations: [Int64: [Int]]
) throws -> GitHubDeliveryTimelineEvidence {
    GitHubDeliveryTimelineEvidence(
        selectedRun: deliveryRun(
            id: 700,
            workflowID: 88,
            name: "CI",
            branch: "feature/timeline",
            headSHA: "final-head",
            pullRequestNumbers: [47],
            updatedAt: Date(timeIntervalSince1970: 100)
        ),
        pullRequest: try pullRequest ?? deliveryPullRequest(),
        baseRuns: baseRuns,
        associatedPullRequestNumbersByRunID: associations
    )
}

private func deliveryPullRequest(
    isMerged: Bool = true,
    mergedAt: Date? = Date(timeIntervalSince1970: 150)
) throws -> GitHubPullRequestMetadata {
    GitHubPullRequestMetadata(
        number: 47,
        state: .closed,
        isDraft: false,
        isMerged: isMerged,
        headRef: "feature/timeline",
        headSHA: "final-head",
        baseRef: "main",
        baseSHA: "base-before-merge",
        mergeCommitSHA: nil,
        webURL: try #require(URL(string: "https://github.com/octocat/project/pull/47")),
        updatedAt: Date(timeIntervalSince1970: 151),
        mergedAt: mergedAt
    )
}

private func deliveryRun(
    id: Int64,
    workflowID: Int64 = 88,
    name: String = "CI",
    branch: String?,
    headSHA: String,
    pullRequestNumbers: [Int] = [],
    updatedAt: Date = Date(timeIntervalSince1970: 300)
) -> GitHubWorkflowRun {
    GitHubWorkflowRun(
        id: id,
        workflowID: workflowID,
        name: name,
        displayTitle: name,
        event: pullRequestNumbers.isEmpty ? "push" : "pull_request",
        status: .completed,
        conclusion: .success,
        runNumber: Int(id),
        headBranch: branch,
        headSHA: headSHA,
        webURL: URL(string: "https://github.com/octocat/project/actions/runs/\(id)")!,
        pullRequestNumbers: pullRequestNumbers,
        createdAt: updatedAt.addingTimeInterval(-30),
        updatedAt: updatedAt
    )
}

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


@Test
func deliveryTimelineBuilderExposesCorrelatedBaseRunWithoutDuplicatingCorrelation() throws {
    let evidence = try deliveryEvidence(
        baseRuns: [deliveryRun(id: 801, branch: "main", headSHA: "landed-sha")],
        associations: [801: [47]]
    )

    let result = GitHubDeliveryTimelineBuilder().buildResult(
        repositoryID: 42,
        evidence: evidence
    )

    #expect(result.timeline.status == .correlated)
    #expect(result.timeline.confidence == .exact)
    #expect(result.correlatedBaseRun?.id == 801)
    #expect(result.correlatedBaseRun?.headSHA == "landed-sha")
}

@Test
func deliveryTimelineBuilderReturnsNoBaseRunWhenCorrelationIsUnavailable() throws {
    let evidence = try deliveryEvidence(
        baseRuns: [deliveryRun(id: 801, branch: "main", headSHA: "landed-sha")],
        associations: [801: [99]]
    )

    let result = GitHubDeliveryTimelineBuilder().buildResult(
        repositoryID: 42,
        evidence: evidence
    )

    #expect(result.timeline.status == .evidenceUnavailable)
    #expect(result.correlatedBaseRun == nil)
}

@Test
func deliveryTimelineBuilderAppendsExactSHADeploymentAfterExecution() throws {
    let original = GitHubDeliveryTimelineBuilder().build(
        repositoryID: 42,
        evidence: try deliveryEvidence(
            baseRuns: [deliveryRun(id: 801, branch: "main", headSHA: "landed-sha")],
            associations: [801: [47]]
        )
    )
    let evidence = GitHubDeploymentTimelineEvidence(
        exactSHA: "LANDED-SHA",
        deployments: [
            GitHubDeploymentEvidence(
                deployment: deploymentFixture(
                    id: 901,
                    sha: " landed-sha ",
                    environment: "production",
                    production: true
                ),
                latestStatus: deploymentStatusFixture(
                    state: .success,
                    environment: "production",
                    environmentURL: URL(string: "https://deploy.example.test/production"),
                    logURL: URL(string: "https://deploy.example.test/logs/901")
                )
            ),
        ]
    )

    let snapshot = GitHubDeliveryTimelineBuilder().appendDeployments(
        to: original,
        evidence: evidence
    )

    #expect(snapshot.status == .correlated)
    #expect(snapshot.confidence == .exact)
    #expect(snapshot.events.map(\.kind) == [.pullRequest, .merge, .execution, .deployment])
    #expect(snapshot.events.last?.title == "Deployment · production")
    #expect(snapshot.events.last?.detail == "Succeeded · Production")
    #expect(snapshot.events.last?.state == .success)
    #expect(snapshot.events.last?.destinationURL?.absoluteString == "https://deploy.example.test/production")
}

@Test
func deliveryTimelineBuilderRejectsMismatchedDeploymentSHAAndNonCorrelatedTimeline() throws {
    let correlated = GitHubDeliveryTimelineBuilder().build(
        repositoryID: 42,
        evidence: try deliveryEvidence(
            baseRuns: [deliveryRun(id: 801, branch: "main", headSHA: "landed-sha")],
            associations: [801: [47]]
        )
    )
    let mismatched = GitHubDeploymentTimelineEvidence(
        exactSHA: "landed-sha",
        deployments: [
            GitHubDeploymentEvidence(
                deployment: deploymentFixture(
                    id: 901,
                    sha: "other-sha",
                    environment: "production",
                    production: true
                ),
                latestStatus: deploymentStatusFixture(
                    state: .success,
                    environment: "production"
                )
            ),
        ]
    )

    let unchangedCorrelated = GitHubDeliveryTimelineBuilder().appendDeployments(
        to: correlated,
        evidence: mismatched
    )
    #expect(unchangedCorrelated == correlated)

    let unavailable = DeliveryTimelineSnapshot(
        status: .evidenceUnavailable,
        confidence: .unknown,
        events: []
    )
    let matchingEvidence = GitHubDeploymentTimelineEvidence(
        exactSHA: "landed-sha",
        deployments: [
            GitHubDeploymentEvidence(
                deployment: deploymentFixture(
                    id: 902,
                    sha: "landed-sha",
                    environment: "production",
                    production: true
                ),
                latestStatus: nil
            ),
        ]
    )

    #expect(
        GitHubDeliveryTimelineBuilder().appendDeployments(
            to: unavailable,
            evidence: matchingEvidence
        ) == unavailable
    )
}

@Test
func deliveryTimelineBuilderUsesEnvironmentFallbackAndStatusURLPriority() throws {
    let original = GitHubDeliveryTimelineBuilder().build(
        repositoryID: 42,
        evidence: try deliveryEvidence(
            baseRuns: [deliveryRun(id: 801, branch: "main", headSHA: "landed-sha")],
            associations: [801: [47]]
        )
    )
    let evidence = GitHubDeploymentTimelineEvidence(
        exactSHA: "landed-sha",
        deployments: [
            GitHubDeploymentEvidence(
                deployment: deploymentFixture(
                    id: 901,
                    sha: "landed-sha",
                    environment: "staging"
                ),
                latestStatus: deploymentStatusFixture(
                    state: .inProgress,
                    environment: "  ",
                    environmentURL: nil,
                    logURL: URL(string: "https://deploy.example.test/logs/901")
                )
            ),
            GitHubDeploymentEvidence(
                deployment: deploymentFixture(
                    id: 902,
                    sha: "landed-sha",
                    environment: ""
                ),
                latestStatus: nil
            ),
        ]
    )

    let snapshot = GitHubDeliveryTimelineBuilder().appendDeployments(
        to: original,
        evidence: evidence
    )
    let deployments = snapshot.events.filter { $0.kind == .deployment }

    #expect(deployments.count == 2)
    #expect(deployments[0].title == "Deployment · staging")
    #expect(deployments[0].detail == "Running")
    #expect(deployments[0].state == .running)
    #expect(deployments[0].destinationURL?.absoluteString == "https://deploy.example.test/logs/901")
    #expect(deployments[1].title == "Deployment · Unknown environment")
    #expect(deployments[1].detail == "Status unavailable")
    #expect(deployments[1].state == .neutral)
}

@Test
func deliveryTimelineBuilderMapsDeploymentStatusesWithoutChangingCorrelationConfidence() throws {
    let original = GitHubDeliveryTimelineBuilder().build(
        repositoryID: 42,
        evidence: try deliveryEvidence(
            baseRuns: [deliveryRun(id: 801, branch: "main", headSHA: "landed-sha")],
            associations: [801: [47]]
        )
    )
    let evidence = GitHubDeploymentTimelineEvidence(
        exactSHA: "landed-sha",
        deployments: [
            deploymentEvidenceFixture(id: 901, state: .failure, environment: "failure"),
            deploymentEvidenceFixture(id: 902, state: .error, environment: "error"),
            deploymentEvidenceFixture(id: 903, state: .pending, environment: "pending"),
            deploymentEvidenceFixture(id: 904, state: .queued, environment: "queued"),
            deploymentEvidenceFixture(id: 905, state: .inactive, environment: "inactive"),
            deploymentEvidenceFixture(id: 906, state: .unknown("future_state"), environment: "future"),
        ]
    )

    let snapshot = GitHubDeliveryTimelineBuilder().appendDeployments(
        to: original,
        evidence: evidence
    )
    let deployments = snapshot.events.filter { $0.kind == .deployment }

    #expect(snapshot.confidence == .exact)
    #expect(deployments.map(\.state) == [.failed, .failed, .waiting, .waiting, .neutral, .neutral])
    #expect(deployments.map(\.detail) == ["Failed", "Error", "Pending", "Queued", "Inactive", "future_state"])
}

private func deploymentFixture(
    id: Int64,
    sha: String,
    environment: String,
    production: Bool = false,
    transient: Bool = false
) -> GitHubDeployment {
    GitHubDeployment(
        id: id,
        sha: sha,
        environment: environment,
        isProductionEnvironment: production,
        isTransientEnvironment: transient,
        createdAt: Date(timeIntervalSince1970: 400),
        updatedAt: Date(timeIntervalSince1970: 500)
    )
}

private func deploymentStatusFixture(
    state: GitHubDeploymentStatusState,
    environment: String?,
    environmentURL: URL? = nil,
    logURL: URL? = nil
) -> GitHubDeploymentStatus {
    GitHubDeploymentStatus(
        id: 1_000,
        state: state,
        environment: environment,
        description: nil,
        environmentURL: environmentURL,
        logURL: logURL,
        createdAt: Date(timeIntervalSince1970: 510),
        updatedAt: Date(timeIntervalSince1970: 520)
    )
}

private func deploymentEvidenceFixture(
    id: Int64,
    state: GitHubDeploymentStatusState,
    environment: String
) -> GitHubDeploymentEvidence {
    GitHubDeploymentEvidence(
        deployment: deploymentFixture(
            id: id,
            sha: "landed-sha",
            environment: environment
        ),
        latestStatus: deploymentStatusFixture(
            state: state,
            environment: environment
        )
    )
}


@Test
func deliveryTimelineBuilderEnrichesDeploymentWithExactEnvironmentProtection() throws {
    let original = GitHubDeliveryTimelineBuilder().build(
        repositoryID: 42,
        evidence: try deliveryEvidence(
            baseRuns: [deliveryRun(id: 801, branch: "main", headSHA: "landed-sha")],
            associations: [801: [47]]
        )
    )
    let evidence = GitHubDeploymentTimelineEvidence(
        exactSHA: "landed-sha",
        deployments: [
            GitHubDeploymentEvidence(
                deployment: deploymentFixture(
                    id: 950,
                    sha: "landed-sha",
                    environment: "staging",
                    production: true
                ),
                latestStatus: deploymentStatusFixture(
                    state: .success,
                    environment: "PRODUCTION",
                    environmentURL: URL(string: "https://deploy.example.test/production")
                )
            ),
        ]
    )
    let catalog = GitHubEnvironmentCatalog(
        totalCount: 1,
        environments: [
            GitHubEnvironment(
                id: 301,
                name: " Production ",
                protection: GitHubEnvironmentProtection(
                    waitTimerMinutes: 30,
                    requiredReviewerCount: 2,
                    preventsSelfReview: true,
                    branchPolicy: .customBranches
                ),
                createdAt: nil,
                updatedAt: nil
            ),
        ],
        isTruncated: false
    )

    let snapshot = GitHubDeliveryTimelineBuilder().appendDeployments(
        to: original,
        evidence: evidence,
        environmentCatalog: catalog
    )

    let deployment = try #require(snapshot.events.last)
    #expect(deployment.kind == .deployment)
    #expect(deployment.title == "Deployment · PRODUCTION")
    #expect(
        deployment.detail
            == "Succeeded · Production · 2 reviewers · 30m wait · No self-review · Custom branches"
    )
    #expect(deployment.state == .success)
    #expect(
        deployment.destinationURL?.absoluteString
            == "https://deploy.example.test/production"
    )
    #expect(snapshot.status == original.status)
    #expect(snapshot.confidence == original.confidence)
}

@Test
func deliveryTimelineBuilderUsesStatusEnvironmentBeforeDeploymentEnvironment() throws {
    let original = GitHubDeliveryTimelineBuilder().build(
        repositoryID: 42,
        evidence: try deliveryEvidence(
            baseRuns: [deliveryRun(id: 801, branch: "main", headSHA: "landed-sha")],
            associations: [801: [47]]
        )
    )
    let evidence = GitHubDeploymentTimelineEvidence(
        exactSHA: "landed-sha",
        deployments: [
            GitHubDeploymentEvidence(
                deployment: deploymentFixture(
                    id: 951,
                    sha: "landed-sha",
                    environment: "staging"
                ),
                latestStatus: deploymentStatusFixture(
                    state: .success,
                    environment: "production"
                )
            ),
        ]
    )
    let catalog = GitHubEnvironmentCatalog(
        totalCount: 2,
        environments: [
            GitHubEnvironment(
                id: 302,
                name: "staging",
                protection: GitHubEnvironmentProtection(
                    waitTimerMinutes: nil,
                    requiredReviewerCount: 3,
                    preventsSelfReview: nil,
                    branchPolicy: .allBranches
                ),
                createdAt: nil,
                updatedAt: nil
            ),
            GitHubEnvironment(
                id: 303,
                name: "production",
                protection: GitHubEnvironmentProtection(
                    waitTimerMinutes: nil,
                    requiredReviewerCount: 1,
                    preventsSelfReview: nil,
                    branchPolicy: .allBranches
                ),
                createdAt: nil,
                updatedAt: nil
            ),
        ],
        isTruncated: false
    )

    let snapshot = GitHubDeliveryTimelineBuilder().appendDeployments(
        to: original,
        evidence: evidence,
        environmentCatalog: catalog
    )

    #expect(snapshot.events.last?.detail == "Succeeded · 1 reviewer")
}

@Test
func deliveryTimelineBuilderLeavesAmbiguousAndUnmatchedEnvironmentsUnchanged() throws {
    let original = GitHubDeliveryTimelineBuilder().build(
        repositoryID: 42,
        evidence: try deliveryEvidence(
            baseRuns: [deliveryRun(id: 801, branch: "main", headSHA: "landed-sha")],
            associations: [801: [47]]
        )
    )
    let evidence = GitHubDeploymentTimelineEvidence(
        exactSHA: "landed-sha",
        deployments: [
            deploymentEvidenceFixture(
                id: 952,
                state: .success,
                environment: "production"
            ),
            deploymentEvidenceFixture(
                id: 953,
                state: .success,
                environment: "unmatched"
            ),
        ]
    )
    let catalog = GitHubEnvironmentCatalog(
        totalCount: 2,
        environments: [
            GitHubEnvironment(
                id: 304,
                name: "production",
                protection: GitHubEnvironmentProtection(
                    waitTimerMinutes: nil,
                    requiredReviewerCount: 1,
                    preventsSelfReview: nil,
                    branchPolicy: .allBranches
                ),
                createdAt: nil,
                updatedAt: nil
            ),
            GitHubEnvironment(
                id: 305,
                name: "PRODUCTION",
                protection: GitHubEnvironmentProtection(
                    waitTimerMinutes: nil,
                    requiredReviewerCount: 4,
                    preventsSelfReview: nil,
                    branchPolicy: .allBranches
                ),
                createdAt: nil,
                updatedAt: nil
            ),
        ],
        isTruncated: false
    )

    let snapshot = GitHubDeliveryTimelineBuilder().appendDeployments(
        to: original,
        evidence: evidence,
        environmentCatalog: catalog
    )
    let deployments = snapshot.events.filter { $0.kind == .deployment }

    #expect(deployments.map(\.detail) == ["Succeeded", "Succeeded"])
}

@Test
func deliveryTimelineBuilderOmitsZeroProtectionValuesAndFormatsWaitTimers() throws {
    let original = GitHubDeliveryTimelineBuilder().build(
        repositoryID: 42,
        evidence: try deliveryEvidence(
            baseRuns: [deliveryRun(id: 801, branch: "main", headSHA: "landed-sha")],
            associations: [801: [47]]
        )
    )
    let evidence = GitHubDeploymentTimelineEvidence(
        exactSHA: "landed-sha",
        deployments: [
            deploymentEvidenceFixture(id: 954, state: .success, environment: "zero"),
            deploymentEvidenceFixture(id: 955, state: .success, environment: "hour"),
            deploymentEvidenceFixture(id: 956, state: .success, environment: "day"),
            deploymentEvidenceFixture(id: 957, state: .success, environment: "minute"),
        ]
    )
    let catalog = GitHubEnvironmentCatalog(
        totalCount: 4,
        environments: [
            GitHubEnvironment(
                id: 306,
                name: "zero",
                protection: GitHubEnvironmentProtection(
                    waitTimerMinutes: 0,
                    requiredReviewerCount: 0,
                    preventsSelfReview: false,
                    branchPolicy: .protectedBranches
                ),
                createdAt: nil,
                updatedAt: nil
            ),
            GitHubEnvironment(
                id: 307,
                name: "hour",
                protection: GitHubEnvironmentProtection(
                    waitTimerMinutes: 120,
                    requiredReviewerCount: nil,
                    preventsSelfReview: nil,
                    branchPolicy: .allBranches
                ),
                createdAt: nil,
                updatedAt: nil
            ),
            GitHubEnvironment(
                id: 308,
                name: "day",
                protection: GitHubEnvironmentProtection(
                    waitTimerMinutes: 2_880,
                    requiredReviewerCount: nil,
                    preventsSelfReview: nil,
                    branchPolicy: .allBranches
                ),
                createdAt: nil,
                updatedAt: nil
            ),
            GitHubEnvironment(
                id: 309,
                name: "minute",
                protection: GitHubEnvironmentProtection(
                    waitTimerMinutes: 90,
                    requiredReviewerCount: nil,
                    preventsSelfReview: nil,
                    branchPolicy: .allBranches
                ),
                createdAt: nil,
                updatedAt: nil
            ),
        ],
        isTruncated: false
    )

    let snapshot = GitHubDeliveryTimelineBuilder().appendDeployments(
        to: original,
        evidence: evidence,
        environmentCatalog: catalog
    )
    let details = snapshot.events
        .filter { $0.kind == .deployment }
        .map(\.detail)

    #expect(details == [
        "Succeeded · Protected branches",
        "Succeeded · 2h wait",
        "Succeeded · 2d wait",
        "Succeeded · 90m wait",
    ])
}

@Test
func deliveryTimelineBuilderWithoutEnvironmentCatalogPreservesDeploymentBehavior() throws {
    let original = GitHubDeliveryTimelineBuilder().build(
        repositoryID: 42,
        evidence: try deliveryEvidence(
            baseRuns: [deliveryRun(id: 801, branch: "main", headSHA: "landed-sha")],
            associations: [801: [47]]
        )
    )
    let evidence = GitHubDeploymentTimelineEvidence(
        exactSHA: "landed-sha",
        deployments: [
            GitHubDeploymentEvidence(
                deployment: deploymentFixture(
                    id: 958,
                    sha: "landed-sha",
                    environment: "production",
                    production: true
                ),
                latestStatus: deploymentStatusFixture(
                    state: .success,
                    environment: "production"
                )
            ),
        ]
    )

    let snapshot = GitHubDeliveryTimelineBuilder().appendDeployments(
        to: original,
        evidence: evidence
    )

    #expect(snapshot.events.last?.detail == "Succeeded · Production")
}

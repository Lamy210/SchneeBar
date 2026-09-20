import Foundation
import SchneeBarCore
import SchneeBarGitHub

public struct GitHubDeliveryTimelineBuildResult: Equatable, Sendable {
    public let timeline: DeliveryTimelineSnapshot
    public let correlatedBaseRun: GitHubWorkflowRun?

    public init(
        timeline: DeliveryTimelineSnapshot,
        correlatedBaseRun: GitHubWorkflowRun?
    ) {
        self.timeline = timeline
        self.correlatedBaseRun = correlatedBaseRun
    }
}

public struct GitHubDeliveryTimelineBuilder: Sendable {
    private let correlator: GitHubWorkflowExecutionCorrelator

    public init(
        correlator: GitHubWorkflowExecutionCorrelator = .init()
    ) {
        self.correlator = correlator
    }

    public func build(
        repositoryID: Int64,
        evidence: GitHubDeliveryTimelineEvidence
    ) -> DeliveryTimelineSnapshot {
        buildResult(
            repositoryID: repositoryID,
            evidence: evidence
        ).timeline
    }

    public func buildResult(
        repositoryID: Int64,
        evidence: GitHubDeliveryTimelineEvidence
    ) -> GitHubDeliveryTimelineBuildResult {
        guard repositoryID > 0 else {
            return unavailableResult(
                evidence: [
                    explanation(
                        id: "repository-context",
                        title: "Repository context",
                        detail: "Repository context is unavailable",
                        state: .missing
                    ),
                ]
            )
        }

        var explanations: [DeliveryTimelineEvidenceItem] = []

        guard let selectedPullRequestNumber = selectedPullRequestNumber(
            in: evidence.selectedRun
        ) else {
            return unavailableResult(
                evidence: [
                    explanation(
                        id: "workflow-pull-request",
                        title: "Workflow pull request",
                        detail: "Workflow does not identify exactly one pull request",
                        state: .missing
                    ),
                ]
            )
        }

        explanations.append(
            explanation(
                id: "workflow-pull-request",
                title: "Workflow pull request",
                detail: "Selected workflow is attached to PR #\(selectedPullRequestNumber)",
                state: .confirmed
            )
        )

        guard let pullRequest = evidence.pullRequest,
              pullRequest.number == selectedPullRequestNumber
        else {
            return unavailableResult(
                evidence: explanations + [
                    explanation(
                        id: "merged-pull-request",
                        title: "Merged pull request",
                        detail: "Merged pull request metadata is unavailable",
                        state: .missing
                    ),
                ]
            )
        }

        guard pullRequest.isMerged,
              let mergedAt = pullRequest.mergedAt
        else {
            return unavailableResult(
                evidence: explanations + [
                    explanation(
                        id: "merged-pull-request",
                        title: "Merged pull request",
                        detail: "PR #\(pullRequest.number) is not proven merged",
                        state: .missing
                    ),
                ]
            )
        }

        explanations.append(
            explanation(
                id: "merged-pull-request",
                title: "Merged pull request",
                detail: "PR #\(pullRequest.number) is merged",
                state: .confirmed
            )
        )

        let baseRef = pullRequest.baseRef
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !baseRef.isEmpty else {
            return unavailableResult(
                evidence: explanations + [
                    explanation(
                        id: "target-branch",
                        title: "Target branch",
                        detail: "Pull request target branch is unavailable",
                        state: .missing
                    ),
                ]
            )
        }

        var foundEligibleTargetBranchRun = false
        var foundCommitAssociation = false

        for candidate in orderedCandidates(
            evidence.baseRuns,
            selectedRun: evidence.selectedRun
        ) {
            let candidateRef = candidate.headBranch?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let candidateSHA = candidate.headSHA
                .trimmingCharacters(in: .whitespacesAndNewlines)

            guard candidate.id != evidence.selectedRun.id,
                  candidateRef == baseRef,
                  !candidateSHA.isEmpty
            else {
                continue
            }

            foundEligibleTargetBranchRun = true

            let associatedPullRequests =
                evidence.associatedPullRequestNumbersByRunID[candidate.id] ?? []
            guard associatedPullRequests.contains(pullRequest.number) else {
                continue
            }

            foundCommitAssociation = true

            let correlation = correlator.correlateMergedPullRequest(
                repositoryID: repositoryID,
                pullRequest: pullRequest,
                pullRequestRun: evidence.selectedRun,
                baseRun: candidate,
                baseCommitPullRequestNumbers: associatedPullRequests
            )
            guard correlation.confidence != .unknown else {
                continue
            }

            var correlatedEvidence = explanations
            correlatedEvidence.append(
                correlationExplanation(
                    correlation,
                    pullRequestNumber: pullRequest.number
                )
            )
            correlatedEvidence.append(
                explanation(
                    id: "target-branch-execution",
                    title: "Target branch execution",
                    detail: targetBranchExecutionDetail(
                        baseRef: baseRef,
                        repositoryDefaultBranch: evidence.repositoryDefaultBranch
                    ),
                    state: .confirmed
                )
            )
            correlatedEvidence.append(
                explanation(
                    id: "commit-association",
                    title: "Commit association",
                    detail: "Target-branch execution is associated with PR #\(pullRequest.number)",
                    state: .confirmed
                )
            )

            let executionBranch = executionBranchLabel(
                baseRef: baseRef,
                repositoryDefaultBranch: evidence.repositoryDefaultBranch
            )
            let timeline = DeliveryTimelineSnapshot(
                status: .correlated,
                confidence: timelineConfidence(correlation.confidence),
                events: [
                    DeliveryTimelineEvent(
                        id: "github-delivery-pr:\(pullRequest.number)",
                        kind: .pullRequest,
                        title: "PR #\(pullRequest.number) workflow",
                        detail: "\(pullRequest.headRef) → \(baseRef)",
                        state: workflowState(evidence.selectedRun),
                        destinationURL: evidence.selectedRun.webURL,
                        occurredAt: evidence.selectedRun.updatedAt
                    ),
                    DeliveryTimelineEvent(
                        id: "github-delivery-merge:\(pullRequest.number)",
                        kind: .merge,
                        title: "Merged",
                        detail: "into \(baseRef)",
                        state: .success,
                        destinationURL: pullRequest.webURL,
                        occurredAt: mergedAt
                    ),
                    DeliveryTimelineEvent(
                        id: "github-delivery-execution:\(candidate.id)",
                        kind: .execution,
                        title: "\(executionBranch) · \(candidate.name)",
                        detail: workflowStatusLabel(candidate),
                        state: workflowState(candidate),
                        destinationURL: candidate.webURL,
                        occurredAt: candidate.updatedAt
                    ),
                ],
                evidence: correlatedEvidence
            )

            return GitHubDeliveryTimelineBuildResult(
                timeline: timeline,
                correlatedBaseRun: candidate
            )
        }

        if !foundEligibleTargetBranchRun {
            return unavailableResult(
                evidence: explanations + [
                    explanation(
                        id: "target-branch-execution",
                        title: "Target branch execution",
                        detail: "No eligible workflow execution was found on target branch \(baseRef)",
                        state: .missing
                    ),
                ]
            )
        }

        if !foundCommitAssociation {
            return unavailableResult(
                evidence: explanations + [
                    explanation(
                        id: "commit-association",
                        title: "Commit association",
                        detail: "No target-branch execution commit was associated with the pull request",
                        state: .missing
                    ),
                ]
            )
        }

        return unavailableResult(
            evidence: explanations + [
                explanation(
                    id: "final-pull-request-revision",
                    title: "Final pull request revision",
                    detail: "Selected workflow could not be verified as the merged pull request's final revision",
                    state: .missing
                ),
            ]
        )
    }

    public func appendDeployments(
        to timeline: DeliveryTimelineSnapshot,
        evidence: GitHubDeploymentTimelineEvidence,
        environmentCatalog: GitHubEnvironmentCatalog? = nil
    ) -> DeliveryTimelineSnapshot {
        guard timeline.status == .correlated else {
            return timeline
        }

        let exactSHA = normalizedSHA(evidence.exactSHA)
        guard !exactSHA.isEmpty else {
            return timeline
        }

        let deploymentEvents = evidence.deployments.compactMap { item -> DeliveryTimelineEvent? in
            let deployment = item.deployment
            guard normalizedSHA(deployment.sha) == exactSHA else {
                return nil
            }

            let status = item.latestStatus
            let environment = normalizedEnvironment(
                status?.environment,
                fallback: deployment.environment
            )
            let presentation = deploymentStatusPresentation(status?.state)
            let matchedEnvironment = matchedEnvironment(
                named: environment,
                in: environmentCatalog
            )
            let detail = deploymentDetail(
                statusLabel: presentation.label,
                deployment: deployment,
                environment: matchedEnvironment
            )

            return DeliveryTimelineEvent(
                id: "github-delivery-deployment:\(deployment.id)",
                kind: .deployment,
                title: "Deployment · \(environment)",
                detail: detail,
                state: presentation.state,
                destinationURL: safeDestinationURL(status?.environmentURL)
                    ?? safeDestinationURL(status?.logURL),
                occurredAt: status?.updatedAt
                    ?? status?.createdAt
                    ?? deployment.updatedAt
                    ?? deployment.createdAt
            )
        }

        guard !deploymentEvents.isEmpty else {
            return timeline
        }

        var explanations = timeline.evidence.filter {
            $0.id != "deployment-commit-match"
        }
        explanations.append(
            explanation(
                id: "deployment-commit-match",
                title: "Deployment commit match",
                detail: deploymentMatchDetail(count: deploymentEvents.count),
                state: .confirmed
            )
        )

        return DeliveryTimelineSnapshot(
            status: timeline.status,
            confidence: timeline.confidence,
            events: timeline.events + deploymentEvents,
            evidence: explanations
        )
    }

    private func selectedPullRequestNumber(in run: GitHubWorkflowRun) -> Int? {
        let numbers = Set(run.pullRequestNumbers.filter { $0 > 0 })
        guard numbers.count == 1 else { return nil }
        return numbers.first
    }

    private func orderedCandidates(
        _ runs: [GitHubWorkflowRun],
        selectedRun: GitHubWorkflowRun
    ) -> [GitHubWorkflowRun] {
        runs.sorted { lhs, rhs in
            let lhsSameWorkflow = lhs.workflowID == selectedRun.workflowID
            let rhsSameWorkflow = rhs.workflowID == selectedRun.workflowID
            if lhsSameWorkflow != rhsSameWorkflow {
                return lhsSameWorkflow
            }
            if lhs.updatedAt != rhs.updatedAt {
                return lhs.updatedAt > rhs.updatedAt
            }
            return lhs.id > rhs.id
        }
    }

    private func executionBranchLabel(
        baseRef: String,
        repositoryDefaultBranch: String?
    ) -> String {
        guard let repositoryDefaultBranch = nonEmpty(repositoryDefaultBranch),
              baseRef.trimmingCharacters(in: .whitespacesAndNewlines)
                == repositoryDefaultBranch
        else {
            return "Base branch"
        }
        return "Default branch"
    }

    private func timelineConfidence(
        _ confidence: GitHubWorkflowExecutionCorrelationConfidence
    ) -> DeliveryTimelineConfidence {
        switch confidence {
        case .exact: return .exact
        case .high: return .high
        case .medium: return .medium
        case .unknown: return .unknown
        }
    }

    private func workflowState(_ run: GitHubWorkflowRun) -> ActivityDetailState {
        switch run.status {
        case .queued, .waiting, .requested, .pending:
            return .waiting
        case .inProgress:
            return .running
        case .completed:
            switch run.conclusion {
            case .success:
                return .success
            case .failure, .timedOut, .actionRequired, .startupFailure:
                return .failed
            case .cancelled, .skipped, .neutral, .stale, .unknown, .none:
                return .neutral
            }
        case .unknown:
            return .neutral
        }
    }

    private func workflowStatusLabel(_ run: GitHubWorkflowRun) -> String {
        switch run.status {
        case .queued, .waiting, .requested, .pending:
            return "Waiting"
        case .inProgress:
            return "Running"
        case .completed:
            switch run.conclusion {
            case .success: return "Succeeded"
            case .failure: return "Failed"
            case .cancelled: return "Cancelled"
            case .skipped: return "Skipped"
            case .timedOut: return "Timed out"
            case .actionRequired: return "Action required"
            case .neutral: return "Neutral"
            case .stale: return "Stale"
            case .startupFailure: return "Startup failure"
            case let .unknown(rawValue):
                return rawValue.isEmpty ? "Completed" : rawValue
            case .none:
                return "Completed"
            }
        case let .unknown(rawValue):
            return rawValue.isEmpty ? "Unknown" : rawValue
        }
    }

    private func deploymentStatusPresentation(
        _ state: GitHubDeploymentStatusState?
    ) -> (label: String, state: ActivityDetailState) {
        switch state {
        case .success:
            return ("Succeeded", .success)
        case .failure:
            return ("Failed", .failed)
        case .error:
            return ("Error", .failed)
        case .inProgress:
            return ("Running", .running)
        case .pending:
            return ("Pending", .waiting)
        case .queued:
            return ("Queued", .waiting)
        case .inactive:
            return ("Inactive", .neutral)
        case let .unknown(rawValue):
            let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
            return (trimmed.isEmpty ? "Unknown" : trimmed, .neutral)
        case .none:
            return ("Status unavailable", .neutral)
        }
    }

    private func deploymentDetail(
        statusLabel: String,
        deployment: GitHubDeployment,
        environment: GitHubEnvironment?
    ) -> String {
        var parts = [statusLabel]

        if deployment.isProductionEnvironment {
            parts.append("Production")
        }
        if deployment.isTransientEnvironment {
            parts.append("Transient")
        }

        if let reviewerCount = environment?.protection.requiredReviewerCount,
           reviewerCount > 0
        {
            parts.append(
                reviewerCount == 1
                    ? "1 reviewer"
                    : "\(reviewerCount) reviewers"
            )
        }

        if let waitTimer = environment?.protection.waitTimerMinutes,
           waitTimer > 0
        {
            parts.append(waitTimerLabel(waitTimer))
        }

        if environment?.protection.preventsSelfReview == true {
            parts.append("No self-review")
        }

        switch environment?.protection.branchPolicy {
        case .protectedBranches:
            parts.append("Protected branches")
        case .customBranches:
            parts.append("Custom branches")
        case .allBranches, .unknown, .none:
            break
        }

        return parts.joined(separator: " · ")
    }

    private func matchedEnvironment(
        named environmentName: String,
        in catalog: GitHubEnvironmentCatalog?
    ) -> GitHubEnvironment? {
        guard let catalog,
              environmentName != "Unknown environment"
        else {
            return nil
        }

        let key = normalizedEnvironmentKey(environmentName)
        guard !key.isEmpty else {
            return nil
        }

        let matches = catalog.environments.filter {
            normalizedEnvironmentKey($0.name) == key
        }
        guard matches.count == 1 else {
            return nil
        }
        return matches[0]
    }

    private func normalizedEnvironmentKey(_ value: String) -> String {
        value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
    }

    private func waitTimerLabel(_ minutes: Int) -> String {
        if minutes % 1_440 == 0 {
            return "\(minutes / 1_440)d wait"
        }
        if minutes % 60 == 0 {
            return "\(minutes / 60)h wait"
        }
        return "\(minutes)m wait"
    }

    private func normalizedEnvironment(
        _ statusEnvironment: String?,
        fallback deploymentEnvironment: String
    ) -> String {
        if let statusEnvironment = nonEmpty(statusEnvironment) {
            return statusEnvironment
        }
        return nonEmpty(deploymentEnvironment) ?? "Unknown environment"
    }

    private func normalizedSHA(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private func nonEmpty(_ value: String?) -> String? {
        guard let value else {
            return nil
        }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private func safeDestinationURL(_ url: URL?) -> URL? {
        guard let url,
              url.scheme?.lowercased() == "https",
              let host = url.host,
              !host.isEmpty,
              url.user == nil,
              url.password == nil
        else {
            return nil
        }
        return url
    }

    private func correlationExplanation(
        _ correlation: GitHubWorkflowExecutionCorrelation,
        pullRequestNumber: Int
    ) -> DeliveryTimelineEvidenceItem {
        switch correlation.reason {
        case .mergedPullRequest:
            return explanation(
                id: "final-pull-request-revision",
                title: "Final pull request revision",
                detail: "Selected workflow represents the merged pull request's final revision",
                state: .confirmed
            )
        case let .sharedPullRequest(number):
            return explanation(
                id: "shared-pull-request",
                title: "Shared pull request",
                detail: "Both workflow executions reference PR #\(number)",
                state: .confirmed
            )
        case .sharedHeadCommit:
            return explanation(
                id: "shared-workflow-commit",
                title: "Shared workflow commit",
                detail: "Selected and target-branch executions share a commit",
                state: .confirmed
            )
        case .sameRun:
            return explanation(
                id: "workflow-execution-identity",
                title: "Workflow execution identity",
                detail: "Both evidence records refer to the same workflow execution",
                state: .confirmed
            )
        case .noReliableEvidence:
            return explanation(
                id: "final-pull-request-revision",
                title: "Final pull request revision",
                detail: "Selected workflow could not be verified as the merged pull request's final revision",
                state: .missing
            )
        }
    }

    private func targetBranchExecutionDetail(
        baseRef: String,
        repositoryDefaultBranch: String?
    ) -> String {
        if let repositoryDefaultBranch = nonEmpty(repositoryDefaultBranch),
           baseRef == repositoryDefaultBranch
        {
            return "Workflow execution found on default branch \(baseRef)"
        }
        return "Workflow execution found on target branch \(baseRef)"
    }

    private func deploymentMatchDetail(count: Int) -> String {
        count == 1
            ? "1 deployment matched the correlated execution commit"
            : "\(count) deployments matched the correlated execution commit"
    }

    private func explanation(
        id: String,
        title: String,
        detail: String,
        state: DeliveryTimelineEvidenceState
    ) -> DeliveryTimelineEvidenceItem {
        DeliveryTimelineEvidenceItem(
            id: id,
            title: title,
            detail: detail,
            state: state
        )
    }

    private func unavailableResult(
        evidence: [DeliveryTimelineEvidenceItem] = []
    ) -> GitHubDeliveryTimelineBuildResult {
        GitHubDeliveryTimelineBuildResult(
            timeline: unavailable(evidence: evidence),
            correlatedBaseRun: nil
        )
    }

    private func unavailable(
        evidence: [DeliveryTimelineEvidenceItem] = []
    ) -> DeliveryTimelineSnapshot {
        DeliveryTimelineSnapshot(
            status: .evidenceUnavailable,
            confidence: .unknown,
            events: [],
            evidence: evidence
        )
    }
}

import Foundation
import SchneeBarCore
import SchneeBarGitHub

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
        guard repositoryID > 0,
              let pullRequest = evidence.pullRequest,
              pullRequest.isMerged,
              let mergedAt = pullRequest.mergedAt,
              selectedPullRequestNumber(in: evidence.selectedRun) == pullRequest.number
        else {
            return unavailable()
        }

        let baseRef = pullRequest.baseRef.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !baseRef.isEmpty else {
            return unavailable()
        }

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

            let associatedPullRequests =
                evidence.associatedPullRequestNumbersByRunID[candidate.id] ?? []
            guard associatedPullRequests.contains(pullRequest.number) else {
                continue
            }

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

            return DeliveryTimelineSnapshot(
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
                        title: "Base branch · \(candidate.name)",
                        detail: workflowStatusLabel(candidate),
                        state: workflowState(candidate),
                        destinationURL: candidate.webURL,
                        occurredAt: candidate.updatedAt
                    ),
                ]
            )
        }

        return unavailable()
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

    private func unavailable() -> DeliveryTimelineSnapshot {
        DeliveryTimelineSnapshot(
            status: .evidenceUnavailable,
            confidence: .unknown,
            events: []
        )
    }
}

import Foundation

public enum GitHubWorkflowExecutionCorrelationConfidence: String, Codable, CaseIterable, Sendable {
    case exact
    case high
    case medium
    case unknown

    fileprivate var rank: Int {
        switch self {
        case .exact: 3
        case .high: 2
        case .medium: 1
        case .unknown: 0
        }
    }
}

public enum GitHubWorkflowExecutionCorrelationReason: Equatable, Sendable {
    case sameRun
    case sharedPullRequest(Int)
    case sharedHeadCommit(String)
    case noReliableEvidence
}

public struct GitHubWorkflowExecutionCorrelation: Equatable, Sendable {
    public let repositoryID: Int64
    public let leftRunID: Int64
    public let rightRunID: Int64
    public let confidence: GitHubWorkflowExecutionCorrelationConfidence
    public let reason: GitHubWorkflowExecutionCorrelationReason

    public init(
        repositoryID: Int64,
        leftRunID: Int64,
        rightRunID: Int64,
        confidence: GitHubWorkflowExecutionCorrelationConfidence,
        reason: GitHubWorkflowExecutionCorrelationReason
    ) {
        self.repositoryID = repositoryID
        self.leftRunID = leftRunID
        self.rightRunID = rightRunID
        self.confidence = confidence
        self.reason = reason
    }
}

/// Correlates workflow executions only when GitHub data provides reliable evidence.
///
/// Branch names, timestamps and workflow names are intentionally not treated as
/// correlation evidence. Those attributes are useful for presentation and later
/// tie-breaking, but using them alone can incorrectly join unrelated pushes.
/// Post-merge PR -> main correlation for squash/rebase merges requires explicit
/// PR/commit ancestry evidence and is deliberately left for a higher layer.
public struct GitHubWorkflowExecutionCorrelator: Sendable {
    public init() {}

    public func correlate(
        repositoryID: Int64,
        left: GitHubWorkflowRun,
        right: GitHubWorkflowRun
    ) -> GitHubWorkflowExecutionCorrelation {
        if left.id == right.id {
            return GitHubWorkflowExecutionCorrelation(
                repositoryID: repositoryID,
                leftRunID: left.id,
                rightRunID: right.id,
                confidence: .exact,
                reason: .sameRun
            )
        }

        if let pullRequest = sharedPullRequest(left, right) {
            return GitHubWorkflowExecutionCorrelation(
                repositoryID: repositoryID,
                leftRunID: left.id,
                rightRunID: right.id,
                confidence: .exact,
                reason: .sharedPullRequest(pullRequest)
            )
        }

        if let commit = sharedHeadCommit(left, right) {
            return GitHubWorkflowExecutionCorrelation(
                repositoryID: repositoryID,
                leftRunID: left.id,
                rightRunID: right.id,
                confidence: .high,
                reason: .sharedHeadCommit(commit)
            )
        }

        return GitHubWorkflowExecutionCorrelation(
            repositoryID: repositoryID,
            leftRunID: left.id,
            rightRunID: right.id,
            confidence: .unknown,
            reason: .noReliableEvidence
        )
    }

    public func bestMatch(
        repositoryID: Int64,
        for target: GitHubWorkflowRun,
        among candidates: [GitHubWorkflowRun]
    ) -> GitHubWorkflowRun? {
        candidates
            .filter { $0.id != target.id }
            .compactMap { candidate -> Candidate? in
                let correlation = correlate(
                    repositoryID: repositoryID,
                    left: target,
                    right: candidate
                )
                guard correlation.confidence != .unknown else {
                    return nil
                }
                return Candidate(run: candidate, confidence: correlation.confidence)
            }
            .sorted(by: candidateSort)
            .first?
            .run
    }

    private func sharedPullRequest(
        _ left: GitHubWorkflowRun,
        _ right: GitHubWorkflowRun
    ) -> Int? {
        let leftNumbers = Set(left.pullRequestNumbers.filter { $0 > 0 })
        return right.pullRequestNumbers
            .filter { $0 > 0 && leftNumbers.contains($0) }
            .min()
    }

    private func sharedHeadCommit(
        _ left: GitHubWorkflowRun,
        _ right: GitHubWorkflowRun
    ) -> String? {
        let leftSHA = normalizedSHA(left.headSHA)
        let rightSHA = normalizedSHA(right.headSHA)
        guard !leftSHA.isEmpty, leftSHA == rightSHA else {
            return nil
        }
        return leftSHA
    }

    private func normalizedSHA(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private func candidateSort(lhs: Candidate, rhs: Candidate) -> Bool {
        if lhs.confidence.rank != rhs.confidence.rank {
            return lhs.confidence.rank > rhs.confidence.rank
        }
        if lhs.run.updatedAt != rhs.run.updatedAt {
            return lhs.run.updatedAt > rhs.run.updatedAt
        }
        return lhs.run.id > rhs.run.id
    }
}

private struct Candidate: Sendable {
    let run: GitHubWorkflowRun
    let confidence: GitHubWorkflowExecutionCorrelationConfidence
}

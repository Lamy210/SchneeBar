import Foundation
import SchneeBarCore
import SchneeBarGitHub

public struct GitHubDeliveryHistoryMapper: Sendable {
    public init() {}

    public func map(
        repository: GitHubRepositoryAccess,
        runs: [GitHubWorkflowRun]
    ) -> DeliveryHistorySnapshot {
        let entries = runs
            .filter { $0.status == .completed }
            .sorted(by: historySort)
            .map { run in
                DeliveryHistoryEntry(
                    id: "github-actions:\(repository.id):\(run.id)",
                    title: run.name,
                    detail: [
                        statusLabel(for: run.conclusion),
                        branchLabel(
                            run.headBranch,
                            defaultBranch: repository.defaultBranch
                        ),
                        "Run #\(run.runNumber)",
                    ].joined(separator: " · "),
                    state: state(for: run.conclusion),
                    destinationURL: run.webURL,
                    occurredAt: run.updatedAt
                )
            }

        return DeliveryHistorySnapshot(
            repository: repository.fullName,
            entries: entries
        )
    }

    private func historySort(
        _ lhs: GitHubWorkflowRun,
        _ rhs: GitHubWorkflowRun
    ) -> Bool {
        if lhs.updatedAt != rhs.updatedAt {
            return lhs.updatedAt > rhs.updatedAt
        }
        return lhs.id > rhs.id
    }

    private func state(
        for conclusion: GitHubWorkflowRunConclusion?
    ) -> ActivityDetailState {
        switch conclusion {
        case .success:
            return .success
        case .failure, .timedOut, .actionRequired, .startupFailure:
            return .failed
        case .cancelled, .skipped, .neutral, .stale, .unknown, .none:
            return .neutral
        }
    }

    private func statusLabel(
        for conclusion: GitHubWorkflowRunConclusion?
    ) -> String {
        switch conclusion {
        case .success:
            return "Succeeded"
        case .failure:
            return "Failed"
        case .cancelled:
            return "Cancelled"
        case .skipped:
            return "Skipped"
        case .timedOut:
            return "Timed out"
        case .actionRequired:
            return "Action required"
        case .neutral:
            return "Neutral"
        case .stale:
            return "Stale"
        case .startupFailure:
            return "Startup failure"
        case .unknown, .none:
            return "Completed"
        }
    }

    private func branchLabel(
        _ branch: String?,
        defaultBranch: String?
    ) -> String {
        guard let branch = normalized(branch) else {
            return "Branch unavailable"
        }
        if let defaultBranch = normalized(defaultBranch),
           branch == defaultBranch
        {
            return "Default branch"
        }
        return branch
    }

    private func normalized(_ value: String?) -> String? {
        guard let value else {
            return nil
        }
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return normalized.isEmpty ? nil : normalized
    }
}

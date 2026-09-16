import SchneeBarCore
import SchneeBarGitHub

public struct GitHubCheckRunActivityMapper: Sendable {
    public init() {}

    public func visibleActivities(
        checks: [GitHubCheckRun],
        repository: GitHubRepositoryAccess,
        visibleWorkflowSHAs: Set<String>
    ) -> [ActivityItem] {
        checks
            .compactMap { check in
                activityItem(
                    check: check,
                    repository: repository,
                    visibleWorkflowSHAs: visibleWorkflowSHAs
                )
            }
            .sorted(by: ActivityInboxOrdering().areInIncreasingOrder)
    }

    private func activityItem(
        check: GitHubCheckRun,
        repository: GitHubRepositoryAccess,
        visibleWorkflowSHAs: Set<String>
    ) -> ActivityItem? {
        if check.appSlug?.lowercased() == "github-actions",
           visibleWorkflowSHAs.contains(check.headSHA)
        {
            return nil
        }

        guard let presentation = presentation(for: check) else {
            return nil
        }

        return ActivityItem(
            id: "github-check:\(repository.id):\(check.id)",
            repository: repository.fullName,
            context: check.name,
            detail: presentation.detail,
            state: presentation.state,
            destinationURL: check.webURL,
            kind: .checkRun,
            attention: presentation.attention,
            updatedAt: check.completedAt ?? check.startedAt
        )
    }

    private func presentation(
        for check: GitHubCheckRun
    ) -> (state: ActivityState, attention: ActivityAttention, detail: String)? {
        switch check.status {
        case .queued, .waiting, .requested, .pending:
            return (.waiting, .active, "Waiting · \(check.name)")
        case .inProgress:
            return (.running, .active, "Running · \(check.name)")
        case .completed:
            return completedPresentation(for: check)
        case .unknown:
            if let conclusion = check.conclusion {
                return conclusionPresentation(conclusion, checkName: check.name)
            }
            return (.waiting, .active, "Waiting · \(check.name)")
        }
    }

    private func completedPresentation(
        for check: GitHubCheckRun
    ) -> (state: ActivityState, attention: ActivityAttention, detail: String)? {
        guard let conclusion = check.conclusion else {
            return (.waiting, .active, "Waiting · \(check.name)")
        }
        return conclusionPresentation(conclusion, checkName: check.name)
    }

    private func conclusionPresentation(
        _ conclusion: GitHubCheckRunConclusion,
        checkName: String
    ) -> (state: ActivityState, attention: ActivityAttention, detail: String)? {
        switch conclusion {
        case .actionRequired:
            return (.failed, .needsAttention, "Action required · \(checkName)")
        case .failure:
            return (.failed, .needsAttention, "Failed · \(checkName)")
        case .timedOut:
            return (.failed, .needsAttention, "Timed out · \(checkName)")
        case .success, .neutral, .skipped, .cancelled, .stale:
            return nil
        case .unknown:
            return (.waiting, .active, "Waiting · \(checkName)")
        }
    }
}

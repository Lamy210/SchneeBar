import Foundation

public enum GitHubWorkflowActivityClassification: Equatable, Sendable {
    case waiting
    case running
    case success
    case failed
    case ignored
}

public struct GitHubWorkflowActivity: Identifiable, Equatable, Sendable {
    public let id: String
    public let repositoryFullName: String
    public let context: String
    public let detail: String
    public let classification: GitHubWorkflowActivityClassification
    public let workflowRunID: Int64
    public let webURL: URL
    public let pullRequestNumbers: [Int]
    public let updatedAt: Date

    public init(
        id: String,
        repositoryFullName: String,
        context: String,
        detail: String,
        classification: GitHubWorkflowActivityClassification,
        workflowRunID: Int64,
        webURL: URL,
        pullRequestNumbers: [Int],
        updatedAt: Date
    ) {
        self.id = id
        self.repositoryFullName = repositoryFullName
        self.context = context
        self.detail = detail
        self.classification = classification
        self.workflowRunID = workflowRunID
        self.webURL = webURL
        self.pullRequestNumbers = pullRequestNumbers
        self.updatedAt = updatedAt
    }
}

public struct GitHubWorkflowActivityMapper: Sendable {
    public init() {}

    public func map(
        run: GitHubWorkflowRun,
        repository: GitHubRepositoryAccess
    ) -> GitHubWorkflowActivity {
        GitHubWorkflowActivity(
            id: "github-actions:\(repository.id):\(run.id)",
            repositoryFullName: repository.fullName,
            context: context(for: run),
            detail: detail(for: run),
            classification: classification(for: run),
            workflowRunID: run.id,
            webURL: run.webURL,
            pullRequestNumbers: run.pullRequestNumbers,
            updatedAt: run.updatedAt
        )
    }

    public func visibleActivities(
        runs: [GitHubWorkflowRun],
        repository: GitHubRepositoryAccess,
        includeSuccessful: Bool = false
    ) -> [GitHubWorkflowActivity] {
        runs
            .map { map(run: $0, repository: repository) }
            .filter { activity in
                switch activity.classification {
                case .ignored:
                    return false
                case .success:
                    return includeSuccessful
                case .waiting, .running, .failed:
                    return true
                }
            }
            .sorted(by: activitySort)
    }

    public func classification(
        for run: GitHubWorkflowRun
    ) -> GitHubWorkflowActivityClassification {
        switch run.status {
        case .queued, .waiting, .requested, .pending:
            return .waiting
        case .inProgress:
            return .running
        case .completed:
            return classification(forCompletedConclusion: run.conclusion)
        case .unknown:
            return run.conclusion == nil ? .waiting : classification(forCompletedConclusion: run.conclusion)
        }
    }

    private func classification(
        forCompletedConclusion conclusion: GitHubWorkflowRunConclusion?
    ) -> GitHubWorkflowActivityClassification {
        guard let conclusion else { return .waiting }

        switch conclusion {
        case .success:
            return .success
        case .failure, .timedOut, .startupFailure, .actionRequired:
            return .failed
        case .cancelled, .skipped, .neutral, .stale:
            return .ignored
        case .unknown:
            return .waiting
        }
    }

    private func context(for run: GitHubWorkflowRun) -> String {
        if let pullRequest = run.pullRequestNumbers.first {
            return "PR #\(pullRequest) · \(run.name)"
        }
        if let branch = run.headBranch {
            return "\(branch) · \(run.name)"
        }
        return run.name
    }

    private func detail(for run: GitHubWorkflowRun) -> String {
        let title = run.displayTitle == run.name ? "Run #\(run.runNumber)" : run.displayTitle
        switch classification(for: run) {
        case .waiting:
            return "Waiting · \(title)"
        case .running:
            return "Running · \(title)"
        case .success:
            return "Succeeded · \(title)"
        case .failed:
            return "Failed · \(title)"
        case .ignored:
            return "Completed · \(title)"
        }
    }

    private func activitySort(
        lhs: GitHubWorkflowActivity,
        rhs: GitHubWorkflowActivity
    ) -> Bool {
        let leftPriority = priority(lhs.classification)
        let rightPriority = priority(rhs.classification)
        if leftPriority != rightPriority {
            return leftPriority < rightPriority
        }
        return lhs.updatedAt > rhs.updatedAt
    }

    private func priority(
        _ classification: GitHubWorkflowActivityClassification
    ) -> Int {
        switch classification {
        case .failed: 0
        case .running: 1
        case .waiting: 2
        case .success: 3
        case .ignored: 4
        }
    }
}

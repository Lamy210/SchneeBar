import Foundation

public enum GitHubWorkflowJobAggregateState: Equatable, Sendable {
    case failed
    case running
    case waiting
    case success
    case unknown
}

public struct GitHubWorkflowFailedStep: Identifiable, Equatable, Sendable {
    public let jobID: Int64
    public let jobName: String
    public let stepNumber: Int
    public let stepName: String
    public let conclusion: GitHubWorkflowJobConclusion
    public let duration: TimeInterval?

    public var id: String {
        "\(jobID):\(stepNumber)"
    }

    public init(
        jobID: Int64,
        jobName: String,
        stepNumber: Int,
        stepName: String,
        conclusion: GitHubWorkflowJobConclusion,
        duration: TimeInterval?
    ) {
        self.jobID = jobID
        self.jobName = jobName
        self.stepNumber = stepNumber
        self.stepName = stepName
        self.conclusion = conclusion
        self.duration = duration
    }
}

/// Summarizes the expanded jobs returned by GitHub Actions.
///
/// Matrix executions are intentionally counted as the distinct jobs GitHub
/// returns. SchneeBar does not infer matrix dimensions from human-readable job
/// names because that would make correlation dependent on naming conventions.
public struct GitHubWorkflowJobSummary: Equatable, Sendable {
    public let totalCount: Int
    public let completedCount: Int
    public let successCount: Int
    public let failedCount: Int
    public let runningCount: Int
    public let waitingCount: Int
    public let cancelledCount: Int
    public let skippedCount: Int
    public let unknownCount: Int
    public let failedJobs: [GitHubWorkflowJob]
    public let failedSteps: [GitHubWorkflowFailedStep]
    public let aggregateState: GitHubWorkflowJobAggregateState

    public init(jobs: [GitHubWorkflowJob]) {
        totalCount = jobs.count
        completedCount = jobs.filter { $0.status == .completed }.count
        successCount = jobs.filter { $0.conclusion == .success }.count
        failedCount = jobs.filter { Self.isFailure($0.conclusion) }.count
        runningCount = jobs.filter { $0.status == .inProgress }.count
        waitingCount = jobs.filter { Self.isWaiting($0.status) }.count
        cancelledCount = jobs.filter { $0.conclusion == .cancelled }.count
        skippedCount = jobs.filter {
            $0.conclusion == .skipped || $0.conclusion == .stale
        }.count
        unknownCount = jobs.filter { Self.isUnknown($0) }.count

        failedJobs = jobs
            .filter { Self.isFailure($0.conclusion) }
            .sorted(by: Self.jobSort)

        failedSteps = jobs
            .flatMap { job in
                job.steps.compactMap { step -> GitHubWorkflowFailedStep? in
                    guard let conclusion = step.conclusion,
                          Self.isFailure(conclusion)
                    else {
                        return nil
                    }

                    return GitHubWorkflowFailedStep(
                        jobID: job.id,
                        jobName: job.name,
                        stepNumber: step.number,
                        stepName: step.name,
                        conclusion: conclusion,
                        duration: step.duration
                    )
                }
            }
            .sorted(by: Self.failedStepSort)

        if failedCount > 0 {
            aggregateState = .failed
        } else if runningCount > 0 {
            aggregateState = .running
        } else if waitingCount > 0 {
            aggregateState = .waiting
        } else if totalCount > 0, unknownCount == 0 {
            aggregateState = .success
        } else {
            aggregateState = .unknown
        }
    }

    public var progressLabel: String {
        "\(completedCount)/\(totalCount) jobs"
    }

    private static func isWaiting(_ status: GitHubWorkflowJobStatus) -> Bool {
        switch status {
        case .queued, .waiting, .pending, .requested:
            return true
        case .inProgress, .completed, .unknown:
            return false
        }
    }

    private static func isFailure(_ conclusion: GitHubWorkflowJobConclusion?) -> Bool {
        guard let conclusion else { return false }
        return isFailure(conclusion)
    }

    private static func isFailure(_ conclusion: GitHubWorkflowJobConclusion) -> Bool {
        switch conclusion {
        case .failure, .timedOut, .actionRequired, .startupFailure:
            return true
        case .success, .cancelled, .skipped, .neutral, .stale, .unknown:
            return false
        }
    }

    private static func isUnknown(_ job: GitHubWorkflowJob) -> Bool {
        if case .unknown = job.status {
            return true
        }
        if let conclusion = job.conclusion,
           case .unknown = conclusion
        {
            return true
        }
        if job.status == .completed, job.conclusion == nil {
            return true
        }
        return false
    }

    private static func jobSort(
        lhs: GitHubWorkflowJob,
        rhs: GitHubWorkflowJob
    ) -> Bool {
        if lhs.name != rhs.name {
            return lhs.name < rhs.name
        }
        return lhs.id < rhs.id
    }

    private static func failedStepSort(
        lhs: GitHubWorkflowFailedStep,
        rhs: GitHubWorkflowFailedStep
    ) -> Bool {
        if lhs.jobName != rhs.jobName {
            return lhs.jobName < rhs.jobName
        }
        if lhs.jobID != rhs.jobID {
            return lhs.jobID < rhs.jobID
        }
        return lhs.stepNumber < rhs.stepNumber
    }
}

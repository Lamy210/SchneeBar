import Foundation
import SchneeBarCore
import SchneeBarGitHub

public struct GitHubActivityJobDetailMapper: Sendable {
    public init() {}

    public func map(
        item: ActivityItem,
        jobs: [GitHubWorkflowJob]
    ) -> ActivityDetailSnapshot {
        let summary = GitHubWorkflowJobSummary(jobs: jobs)
        return ActivityDetailSnapshot(
            id: item.id,
            repository: item.repository,
            title: item.context,
            summary: summaryText(summary),
            state: item.state,
            destinationURL: item.destinationURL,
            rows: jobs
                .sorted(by: jobSort)
                .map(makeDetailRow)
        )
    }

    private func makeDetailRow(_ job: GitHubWorkflowJob) -> ActivityDetailRow {
        ActivityDetailRow(
            id: String(job.id),
            title: job.name,
            detail: jobDetail(job),
            state: jobState(job),
            destinationURL: job.webURL
        )
    }

    private func jobState(_ job: GitHubWorkflowJob) -> ActivityDetailState {
        switch job.status {
        case .inProgress:
            return .running
        case .queued, .waiting, .pending, .requested:
            return .waiting
        case .completed:
            switch job.conclusion {
            case .failure, .timedOut, .actionRequired, .startupFailure:
                return .failed
            case .success:
                return .success
            case .cancelled, .skipped, .neutral, .stale, .none, .unknown:
                return .neutral
            }
        case .unknown:
            return .neutral
        }
    }

    private func jobDetail(_ job: GitHubWorkflowJob) -> String {
        if let failedStep = job.steps.first(where: { isFailure($0.conclusion) }) {
            return "Failed at \(failedStep.name)"
        }

        let status: String
        switch job.status {
        case .inProgress:
            status = "Running"
        case .queued, .waiting, .pending, .requested:
            status = "Waiting"
        case .completed:
            status = conclusionLabel(job.conclusion)
        case let .unknown(rawValue):
            status = rawValue.isEmpty ? "Unknown" : rawValue
        }

        guard let duration = job.duration else { return status }
        return "\(status) · \(durationLabel(duration))"
    }

    private func isFailure(_ conclusion: GitHubWorkflowJobConclusion?) -> Bool {
        switch conclusion {
        case .failure, .timedOut, .actionRequired, .startupFailure:
            return true
        case .none, .success, .cancelled, .skipped, .neutral, .stale, .unknown:
            return false
        }
    }

    private func conclusionLabel(_ conclusion: GitHubWorkflowJobConclusion?) -> String {
        switch conclusion {
        case .success: return "Succeeded"
        case .failure: return "Failed"
        case .cancelled: return "Cancelled"
        case .skipped: return "Skipped"
        case .timedOut: return "Timed out"
        case .actionRequired: return "Action required"
        case .neutral: return "Neutral"
        case .stale: return "Stale"
        case .startupFailure: return "Startup failure"
        case let .unknown(rawValue): return rawValue.isEmpty ? "Unknown" : rawValue
        case .none: return "Completed"
        }
    }

    private func durationLabel(_ duration: TimeInterval) -> String {
        let seconds = max(0, Int(duration.rounded()))
        let minutes = seconds / 60
        let remainingSeconds = seconds % 60
        if minutes == 0 {
            return "\(remainingSeconds)s"
        }
        return "\(minutes)m \(remainingSeconds)s"
    }

    private func summaryText(_ summary: GitHubWorkflowJobSummary) -> String {
        var parts = [summary.progressLabel]
        if summary.failedCount > 0 {
            parts.append("\(summary.failedCount) failed")
        }
        if summary.runningCount > 0 {
            parts.append("\(summary.runningCount) running")
        }
        if summary.waitingCount > 0 {
            parts.append("\(summary.waitingCount) waiting")
        }
        if summary.cancelledCount > 0 {
            parts.append("\(summary.cancelledCount) cancelled")
        }
        return parts.joined(separator: " · ")
    }

    private func jobSort(lhs: GitHubWorkflowJob, rhs: GitHubWorkflowJob) -> Bool {
        let lhsPriority = jobPriority(lhs)
        let rhsPriority = jobPriority(rhs)
        if lhsPriority != rhsPriority {
            return lhsPriority < rhsPriority
        }
        if lhs.name != rhs.name {
            return lhs.name < rhs.name
        }
        return lhs.id < rhs.id
    }

    private func jobPriority(_ job: GitHubWorkflowJob) -> Int {
        switch jobState(job) {
        case .failed: return 0
        case .running: return 1
        case .waiting: return 2
        case .success: return 3
        case .neutral: return 4
        }
    }
}

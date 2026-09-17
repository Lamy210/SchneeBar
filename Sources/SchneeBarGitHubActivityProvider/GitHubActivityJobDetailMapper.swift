import Foundation
import SchneeBarCore
import SchneeBarGitHub

public struct GitHubActivityJobDetailMapper: Sendable {
    private let grouper: GitHubWorkflowJobGrouper

    public init(
        grouper: GitHubWorkflowJobGrouper = GitHubWorkflowJobGrouper()
    ) {
        self.grouper = grouper
    }

    public func map(
        item: ActivityItem,
        jobs: [GitHubWorkflowJob]
    ) -> ActivityDetailSnapshot {
        let summary = GitHubWorkflowJobSummary(jobs: jobs)
        let rows = grouper
            .entries(jobs: jobs)
            .map(makeDetailRow)
            .sorted(by: detailRowSort)

        return ActivityDetailSnapshot(
            id: item.id,
            repository: item.repository,
            title: item.context,
            summary: summaryText(summary),
            state: item.state,
            destinationURL: item.destinationURL,
            rows: rows
        )
    }

    private func makeDetailRow(
        _ entry: GitHubWorkflowJobPresentationEntry
    ) -> ActivityDetailRow {
        switch entry {
        case let .job(job):
            return makeDetailRow(job)
        case let .variantGroup(group):
            return makeGroupDetailRow(group)
        }
    }

    private func makeDetailRow(
        _ job: GitHubWorkflowJob,
        title: String? = nil
    ) -> ActivityDetailRow {
        ActivityDetailRow(
            id: String(job.id),
            title: title ?? job.name,
            detail: jobDetail(job),
            state: jobState(job),
            destinationURL: job.webURL
        )
    }

    private func makeGroupDetailRow(
        _ group: GitHubWorkflowJobVariantGroup
    ) -> ActivityDetailRow {
        let variants = group.variants.sorted(by: variantPresentationSort)
        let children = variants.map { variant in
            makeDetailRow(variant.job, title: variant.label)
        }

        return ActivityDetailRow(
            id: "github-job-group:\(group.runID):\(group.baseName)",
            title: group.baseName,
            detail: groupDetail(variants),
            state: groupState(children),
            destinationURL: nil,
            children: children
        )
    }

    private func groupState(
        _ children: [ActivityDetailRow]
    ) -> ActivityDetailState {
        children
            .map(\.state)
            .min(by: { detailStatePriority($0) < detailStatePriority($1) })
            ?? .neutral
    }

    private func groupDetail(
        _ variants: [GitHubWorkflowJobVariant]
    ) -> String {
        let jobs = variants.map(\.job)
        let states = jobs.map(jobState)
        let failedCount = states.filter { $0 == .failed }.count
        let runningCount = states.filter { $0 == .running }.count
        let waitingCount = states.filter { $0 == .waiting }.count
        let cancelledCount = jobs.filter { $0.conclusion == .cancelled }.count

        var parts = ["\(variants.count) variants"]
        if failedCount > 0 {
            parts.append("\(failedCount) failed")
        }
        if runningCount > 0 {
            parts.append("\(runningCount) running")
        }
        if waitingCount > 0 {
            parts.append("\(waitingCount) waiting")
        }
        if cancelledCount > 0 {
            parts.append("\(cancelledCount) cancelled")
        }
        return parts.joined(separator: " · ")
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

    private func detailRowSort(
        lhs: ActivityDetailRow,
        rhs: ActivityDetailRow
    ) -> Bool {
        let lhsPriority = detailStatePriority(lhs.state)
        let rhsPriority = detailStatePriority(rhs.state)
        if lhsPriority != rhsPriority {
            return lhsPriority < rhsPriority
        }
        if lhs.title != rhs.title {
            return lhs.title < rhs.title
        }
        return lhs.id < rhs.id
    }

    private func variantPresentationSort(
        lhs: GitHubWorkflowJobVariant,
        rhs: GitHubWorkflowJobVariant
    ) -> Bool {
        let lhsPriority = detailStatePriority(jobState(lhs.job))
        let rhsPriority = detailStatePriority(jobState(rhs.job))
        if lhsPriority != rhsPriority {
            return lhsPriority < rhsPriority
        }
        if lhs.label != rhs.label {
            return lhs.label < rhs.label
        }
        return lhs.job.id < rhs.job.id
    }

    private func detailStatePriority(_ state: ActivityDetailState) -> Int {
        switch state {
        case .failed: return 0
        case .running: return 1
        case .waiting: return 2
        case .success: return 3
        case .neutral: return 4
        }
    }
}

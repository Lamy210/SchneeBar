import Foundation
import SchneeBarGitHub

public struct GitHubWorkflowRunSupersessionResolution: Equatable, Sendable {
    public let currentRuns: [GitHubWorkflowRun]
    public let supersededRunIDs: Set<Int64>

    public init(
        currentRuns: [GitHubWorkflowRun],
        supersededRunIDs: Set<Int64>
    ) {
        self.currentRuns = currentRuns
        self.supersededRunIDs = supersededRunIDs
    }
}

public struct GitHubWorkflowRunSupersessionResolver: Sendable {
    public init() {}

    public func resolve(
        runs: [GitHubWorkflowRun]
    ) -> GitHubWorkflowRunSupersessionResolution {
        var runsByLane: [LaneKey: [GitHubWorkflowRun]] = [:]
        var supersededRunIDs = Set<Int64>()

        for run in runs {
            guard let pullRequestNumber = singlePullRequestNumber(run) else { continue }
            let key = LaneKey(
                workflowID: run.workflowID,
                event: run.event,
                pullRequestNumber: pullRequestNumber
            )
            runsByLane[key, default: []].append(run)
        }

        for laneRuns in runsByLane.values {
            guard let maximumRunNumber = laneRuns.map(\.runNumber).max() else { continue }
            let newestRuns = laneRuns.filter { $0.runNumber == maximumRunNumber }
            guard newestRuns.count == 1, let newest = newestRuns.first else { continue }

            let newestSHA = normalizedSHA(newest.headSHA)
            guard !newestSHA.isEmpty else { continue }

            for run in laneRuns where run.runNumber < maximumRunNumber {
                let headSHA = normalizedSHA(run.headSHA)
                guard !headSHA.isEmpty else { continue }
                guard headSHA != newestSHA else { continue }
                supersededRunIDs.insert(run.id)
            }
        }

        let currentRuns = runs
            .filter { !supersededRunIDs.contains($0.id) }
            .sorted(by: runPrecedes)

        return GitHubWorkflowRunSupersessionResolution(
            currentRuns: currentRuns,
            supersededRunIDs: supersededRunIDs
        )
    }

    private func singlePullRequestNumber(_ run: GitHubWorkflowRun) -> Int? {
        let numbers = Set(run.pullRequestNumbers.filter { $0 > 0 })
        guard numbers.count == 1 else { return nil }
        return numbers.first
    }

    private func normalizedSHA(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private func runPrecedes(_ lhs: GitHubWorkflowRun, _ rhs: GitHubWorkflowRun) -> Bool {
        if lhs.updatedAt != rhs.updatedAt {
            return lhs.updatedAt > rhs.updatedAt
        }
        if lhs.runNumber != rhs.runNumber {
            return lhs.runNumber > rhs.runNumber
        }
        return lhs.id > rhs.id
    }
}

private struct LaneKey: Hashable {
    let workflowID: Int64
    let event: String
    let pullRequestNumber: Int
}

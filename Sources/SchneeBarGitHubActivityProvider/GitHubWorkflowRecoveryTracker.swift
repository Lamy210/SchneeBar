import SchneeBarCore
import SchneeBarGitHub

public struct GitHubWorkflowRecoveryTracker: Sendable {
    private var states: [LaneKey: LaneState] = [:]
    private let mapper: GitHubWorkflowActivityMapper

    public init(
        mapper: GitHubWorkflowActivityMapper = GitHubWorkflowActivityMapper()
    ) {
        self.mapper = mapper
    }

    public mutating func observe(
        runs: [GitHubWorkflowRun],
        repository: GitHubRepositoryAccess
    ) -> [DeliveryRecoveryEvent] {
        let newestByLane = newestRunsByLane(
            runs,
            repositoryID: repository.id
        )
        var events: [DeliveryRecoveryEvent] = []

        for (lane, run) in newestByLane.sorted(by: laneEntryPrecedes) {
            let classification = mapper.classification(for: run)

            guard var state = states[lane] else {
                states[lane] = LaneState.seeded(
                    run: run,
                    classification: classification
                )
                continue
            }

            guard state.accepts(run) else {
                continue
            }

            switch classification {
            case .failed:
                state.observe(run)
                state.failureIsArmed = true
                state.armedFailureRunNumber = run.runNumber
                state.armedFailureRunID = run.id

            case .success:
                let shouldEmit = state.failureIsArmed
                    && run.runNumber >= state.armedFailureRunNumber
                    && state.lastEmittedSuccessRunID != run.id

                state.observe(run)

                if shouldEmit {
                    events.append(
                        recoveryEvent(
                            lane: lane,
                            run: run,
                            repository: repository
                        )
                    )
                    state.failureIsArmed = false
                    state.lastEmittedSuccessRunID = run.id
                }

            case .waiting, .running, .ignored:
                state.observe(run)
            }

            states[lane] = state
        }

        return events.sorted(by: recoveryEventPrecedes)
    }

    public mutating func reset(repositoryID: Int64) {
        states = states.filter { $0.key.repositoryID != repositoryID }
    }

    public mutating func reset() {
        states.removeAll(keepingCapacity: false)
    }

    private func newestRunsByLane(
        _ runs: [GitHubWorkflowRun],
        repositoryID: Int64
    ) -> [LaneKey: GitHubWorkflowRun] {
        var newestByLane: [LaneKey: GitHubWorkflowRun] = [:]

        for run in runs {
            guard let pullRequestNumber = singlePullRequestNumber(run) else {
                continue
            }

            let lane = LaneKey(
                repositoryID: repositoryID,
                workflowID: run.workflowID,
                event: run.event,
                pullRequestNumber: pullRequestNumber
            )

            if let current = newestByLane[lane] {
                if runPrecedes(run, current) {
                    newestByLane[lane] = run
                }
            } else {
                newestByLane[lane] = run
            }
        }

        return newestByLane
    }

    private func singlePullRequestNumber(
        _ run: GitHubWorkflowRun
    ) -> Int? {
        let numbers = Set(run.pullRequestNumbers.filter { $0 > 0 })
        guard numbers.count == 1 else {
            return nil
        }
        return numbers.first
    }

    private func runPrecedes(
        _ lhs: GitHubWorkflowRun,
        _ rhs: GitHubWorkflowRun
    ) -> Bool {
        if lhs.runNumber != rhs.runNumber {
            return lhs.runNumber > rhs.runNumber
        }
        if lhs.updatedAt != rhs.updatedAt {
            return lhs.updatedAt > rhs.updatedAt
        }
        return lhs.id > rhs.id
    }

    private func laneEntryPrecedes(
        _ lhs: Dictionary<LaneKey, GitHubWorkflowRun>.Element,
        _ rhs: Dictionary<LaneKey, GitHubWorkflowRun>.Element
    ) -> Bool {
        if lhs.value.updatedAt != rhs.value.updatedAt {
            return lhs.value.updatedAt < rhs.value.updatedAt
        }
        return lhs.key.sortKey < rhs.key.sortKey
    }

    private func recoveryEvent(
        lane: LaneKey,
        run: GitHubWorkflowRun,
        repository: GitHubRepositoryAccess
    ) -> DeliveryRecoveryEvent {
        DeliveryRecoveryEvent(
            id: "github-delivery-recovery:\(repository.id):\(lane.workflowID):\(lane.event):\(lane.pullRequestNumber):\(run.id)",
            repository: repository.fullName,
            title: "CI recovered",
            detail: "PR #\(lane.pullRequestNumber) succeeded after a previously observed failed workflow run",
            destinationURL: run.webURL,
            occurredAt: run.updatedAt
        )
    }

    private func recoveryEventPrecedes(
        _ lhs: DeliveryRecoveryEvent,
        _ rhs: DeliveryRecoveryEvent
    ) -> Bool {
        if lhs.occurredAt != rhs.occurredAt {
            return lhs.occurredAt > rhs.occurredAt
        }
        return lhs.id < rhs.id
    }
}

private struct LaneKey: Hashable, Sendable {
    let repositoryID: Int64
    let workflowID: Int64
    let event: String
    let pullRequestNumber: Int

    var sortKey: String {
        "\(repositoryID):\(workflowID):\(event):\(pullRequestNumber)"
    }
}

private struct LaneState: Sendable {
    var latestRunNumber: Int
    var latestRunID: Int64
    var latestUpdatedAt: Date
    var failureIsArmed: Bool
    var armedFailureRunNumber: Int
    var armedFailureRunID: Int64?
    var lastEmittedSuccessRunID: Int64?

    static func seeded(
        run: GitHubWorkflowRun,
        classification: GitHubWorkflowActivityClassification
    ) -> LaneState {
        let failed = classification == .failed
        return LaneState(
            latestRunNumber: run.runNumber,
            latestRunID: run.id,
            latestUpdatedAt: run.updatedAt,
            failureIsArmed: failed,
            armedFailureRunNumber: failed ? run.runNumber : -1,
            armedFailureRunID: failed ? run.id : nil,
            lastEmittedSuccessRunID: nil
        )
    }

    func accepts(_ run: GitHubWorkflowRun) -> Bool {
        if run.runNumber != latestRunNumber {
            return run.runNumber > latestRunNumber
        }
        if run.id == latestRunID {
            return run.updatedAt >= latestUpdatedAt
        }
        if run.updatedAt != latestUpdatedAt {
            return run.updatedAt > latestUpdatedAt
        }
        return run.id > latestRunID
    }

    mutating func observe(_ run: GitHubWorkflowRun) {
        latestRunNumber = run.runNumber
        latestRunID = run.id
        latestUpdatedAt = run.updatedAt
    }
}

import Foundation
import SchneeBarCore
import SchneeBarGitHub

public enum GitHubRepositoryActivityFailureReason: Equatable, Sendable {
    case authenticationRequired
    case forbidden
    case notFound
    case networkUnavailable
    case unavailable
}

public struct GitHubRepositoryActivityFailure: Equatable, Sendable {
    public let repositoryID: Int64
    public let repositoryFullName: String
    public let reason: GitHubRepositoryActivityFailureReason

    public init(
        repositoryID: Int64,
        repositoryFullName: String,
        reason: GitHubRepositoryActivityFailureReason
    ) {
        self.repositoryID = repositoryID
        self.repositoryFullName = repositoryFullName
        self.reason = reason
    }
}

public struct GitHubActivityLoadResult: Equatable, Sendable {
    public let items: [ActivityItem]
    public let failures: [GitHubRepositoryActivityFailure]

    public init(
        items: [ActivityItem],
        failures: [GitHubRepositoryActivityFailure]
    ) {
        self.items = items
        self.failures = failures
    }
}

public struct GitHubActivityProvider: Sendable {
    private let workflowRunLoader: any GitHubWorkflowRunLoading
    private let activityMapper: GitHubWorkflowActivityMapper
    private let maximumConcurrentRepositories: Int
    private let perRepositoryRunLimit: Int

    public init(
        workflowRunLoader: any GitHubWorkflowRunLoading,
        activityMapper: GitHubWorkflowActivityMapper = GitHubWorkflowActivityMapper(),
        maximumConcurrentRepositories: Int = 4,
        perRepositoryRunLimit: Int = 20
    ) {
        self.workflowRunLoader = workflowRunLoader
        self.activityMapper = activityMapper
        self.maximumConcurrentRepositories = max(1, maximumConcurrentRepositories)
        self.perRepositoryRunLimit = min(max(1, perRepositoryRunLimit), 100)
    }

    public func load(
        profile: GitHubConnectionProfile,
        inventory: GitHubAccessInventory
    ) async -> GitHubActivityLoadResult {
        guard profile.isEnabled else {
            return GitHubActivityLoadResult(items: [], failures: [])
        }

        let repositories = monitoredRepositories(
            selection: profile.repositorySelection,
            inventory: inventory
        )
        guard !repositories.isEmpty else {
            return GitHubActivityLoadResult(items: [], failures: [])
        }

        let outcomes = await loadRepositories(
            repositories,
            profile: profile
        )

        var activities: [GitHubWorkflowActivity] = []
        var failures: [GitHubRepositoryActivityFailure] = []

        for outcome in outcomes {
            switch outcome {
            case let .success(repositoryActivities):
                activities.append(contentsOf: repositoryActivities)
            case let .failure(failure):
                failures.append(failure)
            }
        }

        activities.sort(by: activitySort)
        failures.sort { lhs, rhs in
            if lhs.repositoryFullName != rhs.repositoryFullName {
                return lhs.repositoryFullName < rhs.repositoryFullName
            }
            return lhs.repositoryID < rhs.repositoryID
        }

        return GitHubActivityLoadResult(
            items: activities.map(makeActivityItem),
            failures: failures
        )
    }

    private func monitoredRepositories(
        selection: GitHubRepositoryMonitoringSelection,
        inventory: GitHubAccessInventory
    ) -> [GitHubRepositoryAccess] {
        var seen = Set<Int64>()
        return inventory.installations
            .filter { $0.status == .available }
            .flatMap(\.repositories)
            .filter { selection.includes(repositoryID: $0.id) }
            .filter { seen.insert($0.id).inserted }
            .sorted { lhs, rhs in
                if lhs.fullName != rhs.fullName {
                    return lhs.fullName < rhs.fullName
                }
                return lhs.id < rhs.id
            }
    }

    private func loadRepositories(
        _ repositories: [GitHubRepositoryAccess],
        profile: GitHubConnectionProfile
    ) async -> [RepositoryLoadOutcome] {
        await withTaskGroup(of: RepositoryLoadOutcome.self) { group in
            var iterator = repositories.makeIterator()
            var activeTasks = 0

            while activeTasks < maximumConcurrentRepositories,
                  let repository = iterator.next()
            {
                addLoadTask(
                    repository: repository,
                    profile: profile,
                    to: &group
                )
                activeTasks += 1
            }

            var outcomes: [RepositoryLoadOutcome] = []
            outcomes.reserveCapacity(repositories.count)

            while let outcome = await group.next() {
                outcomes.append(outcome)
                activeTasks -= 1

                if let repository = iterator.next() {
                    addLoadTask(
                        repository: repository,
                        profile: profile,
                        to: &group
                    )
                    activeTasks += 1
                }
            }

            return outcomes
        }
    }

    private func addLoadTask(
        repository: GitHubRepositoryAccess,
        profile: GitHubConnectionProfile,
        to group: inout TaskGroup<RepositoryLoadOutcome>
    ) {
        let workflowRunLoader = self.workflowRunLoader
        let activityMapper = self.activityMapper
        let runLimit = perRepositoryRunLimit

        group.addTask {
            do {
                let runs = try await workflowRunLoader.workflowRuns(
                    connection: profile.connection,
                    identity: profile.account,
                    clientID: profile.clientID,
                    repository: repository,
                    query: GitHubWorkflowRunQuery(limit: runLimit)
                )
                let activities = activityMapper.visibleActivities(
                    runs: runs,
                    repository: repository
                )
                return .success(activities)
            } catch {
                return .failure(
                    GitHubRepositoryActivityFailure(
                        repositoryID: repository.id,
                        repositoryFullName: repository.fullName,
                        reason: failureReason(for: error)
                    )
                )
            }
        }
    }

    private func failureReason(
        for error: Error
    ) -> GitHubRepositoryActivityFailureReason {
        switch error {
        case GitHubConnectionSessionError.credentialNotFound,
             GitHubConnectionSessionError.reauthenticationRequired,
             GitHubConnectionSessionError.accountMismatch(_, _),
             GitHubActionsClientError.httpStatus(401):
            return .authenticationRequired
        case GitHubActionsClientError.httpStatus(403):
            return .forbidden
        case GitHubActionsClientError.httpStatus(404):
            return .notFound
        case let error as URLError where error.code == .notConnectedToInternet
            || error.code == .cannotFindHost
            || error.code == .cannotConnectToHost
            || error.code == .dnsLookupFailed
            || error.code == .timedOut:
            return .networkUnavailable
        default:
            return .unavailable
        }
    }

    private func makeActivityItem(
        _ activity: GitHubWorkflowActivity
    ) -> ActivityItem {
        ActivityItem(
            id: activity.id,
            repository: activity.repositoryFullName,
            context: activity.context,
            detail: activity.detail,
            state: activityState(activity.classification)
        )
    }

    private func activityState(
        _ classification: GitHubWorkflowActivityClassification
    ) -> ActivityState {
        switch classification {
        case .waiting:
            return .waiting
        case .running:
            return .running
        case .success:
            return .success
        case .failed:
            return .failed
        case .ignored:
            return .waiting
        }
    }

    private func activitySort(
        lhs: GitHubWorkflowActivity,
        rhs: GitHubWorkflowActivity
    ) -> Bool {
        let lhsPriority = priority(lhs.classification)
        let rhsPriority = priority(rhs.classification)
        if lhsPriority != rhsPriority {
            return lhsPriority < rhsPriority
        }
        if lhs.updatedAt != rhs.updatedAt {
            return lhs.updatedAt > rhs.updatedAt
        }
        return lhs.id < rhs.id
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

private enum RepositoryLoadOutcome: Sendable {
    case success([GitHubWorkflowActivity])
    case failure(GitHubRepositoryActivityFailure)
}

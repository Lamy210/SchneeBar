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
    public let successfulRepositoryCount: Int
    public let attemptedRepositoryCount: Int

    public init(
        items: [ActivityItem],
        failures: [GitHubRepositoryActivityFailure],
        successfulRepositoryCount: Int,
        attemptedRepositoryCount: Int
    ) {
        self.items = items
        self.failures = failures
        self.successfulRepositoryCount = successfulRepositoryCount
        self.attemptedRepositoryCount = attemptedRepositoryCount
    }
}

/// Aggregates GitHub Actions activity under an explicit request budget.
///
/// Large GitHub accounts can expose hundreds of repositories. Polling every
/// repository on the widget's active cadence would exhaust REST API quotas and
/// waste battery. The provider therefore keeps per-repository poll state:
/// repositories with visible CI activity stay hot, while a reserved part of
/// every refresh scans the least-recently-polled cold repositories.
public actor GitHubActivityProvider {
    private let workflowRunLoader: any GitHubWorkflowRunLoading
    private let activityMapper: GitHubWorkflowActivityMapper
    private let maximumConcurrentRepositories: Int
    private let perRepositoryRunLimit: Int
    private let maximumRepositoriesPerRefresh: Int
    private let minimumColdRepositoriesPerRefresh: Int
    private let now: @Sendable () -> Date

    private var pollState: [RepositoryPollKey: RepositoryPollState] = [:]
    private var cachedActivities: [RepositoryPollKey: [GitHubWorkflowActivity]] = [:]
    private var loadsInProgress: Set<UUID> = []
    private var lastResultByConnectionID: [UUID: GitHubActivityLoadResult] = [:]

    public init(
        workflowRunLoader: any GitHubWorkflowRunLoading,
        activityMapper: GitHubWorkflowActivityMapper = GitHubWorkflowActivityMapper(),
        maximumConcurrentRepositories: Int = 4,
        perRepositoryRunLimit: Int = 20,
        maximumRepositoriesPerRefresh: Int = 8,
        minimumColdRepositoriesPerRefresh: Int = 2,
        now: @escaping @Sendable () -> Date = { .now }
    ) {
        self.workflowRunLoader = workflowRunLoader
        self.activityMapper = activityMapper
        self.maximumConcurrentRepositories = max(1, maximumConcurrentRepositories)
        self.perRepositoryRunLimit = min(max(1, perRepositoryRunLimit), 100)
        self.maximumRepositoriesPerRefresh = max(1, maximumRepositoriesPerRefresh)
        self.minimumColdRepositoriesPerRefresh = max(0, minimumColdRepositoriesPerRefresh)
        self.now = now
    }

    public func load(
        profile: GitHubConnectionProfile,
        inventory: GitHubAccessInventory
    ) async -> GitHubActivityLoadResult {
        guard profile.isEnabled else {
            reset(connectionID: profile.id)
            return emptyResult()
        }

        if loadsInProgress.contains(profile.id) {
            return lastResultByConnectionID[profile.id] ?? emptyResult()
        }

        let repositories = monitoredRepositories(
            selection: profile.repositorySelection,
            inventory: inventory
        )
        pruneState(connectionID: profile.id, repositories: repositories)

        guard !repositories.isEmpty else {
            let result = emptyResult()
            lastResultByConnectionID[profile.id] = result
            return result
        }

        let repositoriesToPoll = repositoriesForRefresh(
            connectionID: profile.id,
            repositories: repositories
        )
        guard !repositoriesToPoll.isEmpty else {
            return cachedResult(
                connectionID: profile.id,
                failures: [],
                successfulRepositoryCount: 0,
                attemptedRepositoryCount: 0
            )
        }

        loadsInProgress.insert(profile.id)
        defer { loadsInProgress.remove(profile.id) }

        let outcomes = await loadRepositories(
            repositoriesToPoll,
            profile: profile
        )

        var failures: [GitHubRepositoryActivityFailure] = []
        var successfulRepositoryCount = 0

        for outcome in outcomes {
            switch outcome {
            case let .success(repositoryID, repositoryActivities):
                successfulRepositoryCount += 1
                let key = RepositoryPollKey(
                    connectionID: profile.id,
                    repositoryID: repositoryID
                )
                cachedActivities[key] = repositoryActivities
                pollState[key, default: RepositoryPollState()].isHot = !repositoryActivities.isEmpty
            case let .failure(failure):
                failures.append(failure)
            }
        }

        failures.sort(by: failureSort)
        let result = cachedResult(
            connectionID: profile.id,
            failures: failures,
            successfulRepositoryCount: successfulRepositoryCount,
            attemptedRepositoryCount: repositoriesToPoll.count
        )
        lastResultByConnectionID[profile.id] = result
        return result
    }

    public func reset(connectionID: UUID) {
        pollState = pollState.filter { $0.key.connectionID != connectionID }
        cachedActivities = cachedActivities.filter { $0.key.connectionID != connectionID }
        lastResultByConnectionID.removeValue(forKey: connectionID)
        loadsInProgress.remove(connectionID)
    }

    private func cachedResult(
        connectionID: UUID,
        failures: [GitHubRepositoryActivityFailure],
        successfulRepositoryCount: Int,
        attemptedRepositoryCount: Int
    ) -> GitHubActivityLoadResult {
        let activities = cachedActivities
            .filter { $0.key.connectionID == connectionID }
            .values
            .flatMap { $0 }
            .sorted(by: activitySort)

        return GitHubActivityLoadResult(
            items: activities.map(makeActivityItem),
            failures: failures,
            successfulRepositoryCount: successfulRepositoryCount,
            attemptedRepositoryCount: attemptedRepositoryCount
        )
    }

    private func emptyResult() -> GitHubActivityLoadResult {
        GitHubActivityLoadResult(
            items: [],
            failures: [],
            successfulRepositoryCount: 0,
            attemptedRepositoryCount: 0
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
            .sorted(by: repositorySort)
    }

    private func repositoriesForRefresh(
        connectionID: UUID,
        repositories: [GitHubRepositoryAccess]
    ) -> [GitHubRepositoryAccess] {
        let budget = min(maximumRepositoriesPerRefresh, repositories.count)
        let timestamp = now()

        let hot = repositories
            .filter {
                pollState[
                    RepositoryPollKey(connectionID: connectionID, repositoryID: $0.id)
                ]?.isHot == true
            }
            .sorted {
                pollCandidateSort(
                    lhs: $0,
                    rhs: $1,
                    connectionID: connectionID
                )
            }
        let cold = repositories
            .filter {
                pollState[
                    RepositoryPollKey(connectionID: connectionID, repositoryID: $0.id)
                ]?.isHot != true
            }
            .sorted {
                pollCandidateSort(
                    lhs: $0,
                    rhs: $1,
                    connectionID: connectionID
                )
            }

        let reservedCold = min(minimumColdRepositoriesPerRefresh, cold.count, budget)
        let hotBudget = budget - reservedCold

        var selected = Array(hot.prefix(hotBudget))
        let remaining = budget - selected.count
        selected.append(contentsOf: cold.prefix(remaining))

        if selected.count < budget {
            let selectedIDs = Set(selected.map(\.id))
            selected.append(
                contentsOf: hot
                    .filter { !selectedIDs.contains($0.id) }
                    .prefix(budget - selected.count)
            )
        }

        for repository in selected {
            let key = RepositoryPollKey(
                connectionID: connectionID,
                repositoryID: repository.id
            )
            pollState[key, default: RepositoryPollState()].lastPolledAt = timestamp
        }

        return selected
    }

    private func pollCandidateSort(
        lhs: GitHubRepositoryAccess,
        rhs: GitHubRepositoryAccess,
        connectionID: UUID
    ) -> Bool {
        let lhsKey = RepositoryPollKey(connectionID: connectionID, repositoryID: lhs.id)
        let rhsKey = RepositoryPollKey(connectionID: connectionID, repositoryID: rhs.id)
        let lhsDate = pollState[lhsKey]?.lastPolledAt
        let rhsDate = pollState[rhsKey]?.lastPolledAt

        switch (lhsDate, rhsDate) {
        case (nil, nil):
            return repositorySort(lhs: lhs, rhs: rhs)
        case (nil, _):
            return true
        case (_, nil):
            return false
        case let (lhsDate?, rhsDate?):
            if lhsDate != rhsDate {
                return lhsDate < rhsDate
            }
            return repositorySort(lhs: lhs, rhs: rhs)
        }
    }

    private func pruneState(
        connectionID: UUID,
        repositories: [GitHubRepositoryAccess]
    ) {
        let validRepositoryIDs = Set(repositories.map(\.id))
        pollState = pollState.filter { key, _ in
            key.connectionID != connectionID || validRepositoryIDs.contains(key.repositoryID)
        }
        cachedActivities = cachedActivities.filter { key, _ in
            key.connectionID != connectionID || validRepositoryIDs.contains(key.repositoryID)
        }
    }

    private func loadRepositories(
        _ repositories: [GitHubRepositoryAccess],
        profile: GitHubConnectionProfile
    ) async -> [RepositoryLoadOutcome] {
        let maximumConcurrentRepositories = self.maximumConcurrentRepositories
        let perRepositoryRunLimit = self.perRepositoryRunLimit
        let workflowRunLoader = self.workflowRunLoader
        let activityMapper = self.activityMapper

        return await withTaskGroup(of: RepositoryLoadOutcome.self) { group in
            var iterator = repositories.makeIterator()
            var activeTasks = 0

            func addTask(for repository: GitHubRepositoryAccess) {
                group.addTask {
                    do {
                        let runs = try await workflowRunLoader.workflowRuns(
                            connection: profile.connection,
                            identity: profile.account,
                            clientID: profile.clientID,
                            repository: repository,
                            query: GitHubWorkflowRunQuery(limit: perRepositoryRunLimit)
                        )
                        let activities = activityMapper.visibleActivities(
                            runs: runs,
                            repository: repository
                        )
                        return .success(
                            repositoryID: repository.id,
                            activities: activities
                        )
                    } catch {
                        return .failure(
                            GitHubRepositoryActivityFailure(
                                repositoryID: repository.id,
                                repositoryFullName: repository.fullName,
                                reason: Self.failureReason(for: error)
                            )
                        )
                    }
                }
            }

            while activeTasks < maximumConcurrentRepositories,
                  let repository = iterator.next()
            {
                addTask(for: repository)
                activeTasks += 1
            }

            var outcomes: [RepositoryLoadOutcome] = []
            outcomes.reserveCapacity(repositories.count)

            while let outcome = await group.next() {
                outcomes.append(outcome)
                activeTasks -= 1

                if let repository = iterator.next() {
                    addTask(for: repository)
                    activeTasks += 1
                }
            }

            return outcomes
        }
    }

    private static func failureReason(
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

    private func repositorySort(
        lhs: GitHubRepositoryAccess,
        rhs: GitHubRepositoryAccess
    ) -> Bool {
        if lhs.fullName != rhs.fullName {
            return lhs.fullName < rhs.fullName
        }
        return lhs.id < rhs.id
    }

    private func failureSort(
        lhs: GitHubRepositoryActivityFailure,
        rhs: GitHubRepositoryActivityFailure
    ) -> Bool {
        if lhs.repositoryFullName != rhs.repositoryFullName {
            return lhs.repositoryFullName < rhs.repositoryFullName
        }
        return lhs.repositoryID < rhs.repositoryID
    }
}

private struct RepositoryPollKey: Hashable, Sendable {
    let connectionID: UUID
    let repositoryID: Int64
}

private struct RepositoryPollState: Sendable {
    var lastPolledAt: Date?
    var isHot = false
}

private enum RepositoryLoadOutcome: Sendable {
    case success(repositoryID: Int64, activities: [GitHubWorkflowActivity])
    case failure(GitHubRepositoryActivityFailure)
}

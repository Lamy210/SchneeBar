import Foundation
import SchneeBarCore
import SchneeBarGitHub

/// Aggregates GitHub Workflow, direct Review Request, and Check activity under
/// explicit per-source request budgets while keeping source caches isolated.
public actor GitHubActivityProvider {
    private let workflowRunLoader: any GitHubWorkflowRunLoading
    private let reviewRequestLoader: (any GitHubReviewRequestLoading)?
    private let checkRunLoader: (any GitHubCheckRunLoading)?
    private let activityMapper: GitHubWorkflowActivityMapper
    private let reviewRequestMapper: GitHubReviewRequestActivityMapper
    private let checkRunMapper: GitHubCheckRunActivityMapper
    private let checkCandidatePlanner: GitHubCheckCandidatePlanner
    private let workflowRunSupersessionResolver: GitHubWorkflowRunSupersessionResolver
    private let maximumConcurrentRepositories: Int
    private let perRepositoryRunLimit: Int
    private let maximumRepositoriesPerRefresh: Int
    private let maximumReviewRepositoriesPerRefresh: Int
    private let maximumCheckTargetsPerRefresh: Int
    private let maximumCheckTargetsPerRepository: Int
    private let minimumColdRepositoriesPerRefresh: Int
    private let minimumColdReviewRepositoriesPerRefresh: Int
    private let now: @Sendable () -> Date

    private var workflowPollState: [RepositoryPollKey: RepositoryPollState] = [:]
    private var reviewPollState: [RepositoryPollKey: RepositoryPollState] = [:]
    private var cachedWorkflowActivities: [RepositoryPollKey: [GitHubWorkflowActivity]] = [:]
    private var workflowEvidence: [RepositoryPollKey: [GitHubWorkflowEvidence]] = [:]
    private var workflowRecoveryTrackers: [RepositoryPollKey: GitHubWorkflowRecoveryTracker] = [:]
    private var cachedReviewRequests: [RepositoryPollKey: [GitHubReviewRequest]] = [:]
    private var cachedCheckActivities: [CheckPollKey: [ActivityItem]] = [:]
    private var loadsInProgress: Set<UUID> = []
    private var generationByConnectionID: [UUID: UInt64] = [:]
    private var lastResultByConnectionID: [UUID: GitHubActivityLoadResult] = [:]

    public init(
        workflowRunLoader: any GitHubWorkflowRunLoading,
        reviewRequestLoader: (any GitHubReviewRequestLoading)? = nil,
        checkRunLoader: (any GitHubCheckRunLoading)? = nil,
        activityMapper: GitHubWorkflowActivityMapper = GitHubWorkflowActivityMapper(),
        reviewRequestMapper: GitHubReviewRequestActivityMapper = GitHubReviewRequestActivityMapper(),
        checkRunMapper: GitHubCheckRunActivityMapper = GitHubCheckRunActivityMapper(),
        workflowRunSupersessionResolver: GitHubWorkflowRunSupersessionResolver = GitHubWorkflowRunSupersessionResolver(),
        maximumConcurrentRepositories: Int = 4,
        perRepositoryRunLimit: Int = 20,
        maximumRepositoriesPerRefresh: Int = 8,
        maximumReviewRepositoriesPerRefresh: Int = 4,
        maximumCheckTargetsPerRefresh: Int = 4,
        maximumCheckTargetsPerRepository: Int = 2,
        minimumColdRepositoriesPerRefresh: Int = 2,
        minimumColdReviewRepositoriesPerRefresh: Int = 1,
        now: @escaping @Sendable () -> Date = { .now }
    ) {
        self.workflowRunLoader = workflowRunLoader
        self.reviewRequestLoader = reviewRequestLoader
        self.checkRunLoader = checkRunLoader
        self.activityMapper = activityMapper
        self.reviewRequestMapper = reviewRequestMapper
        self.checkRunMapper = checkRunMapper
        self.workflowRunSupersessionResolver = workflowRunSupersessionResolver
        checkCandidatePlanner = GitHubCheckCandidatePlanner()
        self.maximumConcurrentRepositories = max(1, maximumConcurrentRepositories)
        self.perRepositoryRunLimit = min(max(1, perRepositoryRunLimit), 100)
        self.maximumRepositoriesPerRefresh = max(1, maximumRepositoriesPerRefresh)
        self.maximumReviewRepositoriesPerRefresh = max(1, maximumReviewRepositoriesPerRefresh)
        self.maximumCheckTargetsPerRefresh = max(1, maximumCheckTargetsPerRefresh)
        self.maximumCheckTargetsPerRepository = max(1, maximumCheckTargetsPerRepository)
        self.minimumColdRepositoriesPerRefresh = max(0, minimumColdRepositoriesPerRefresh)
        self.minimumColdReviewRepositoriesPerRefresh = max(0, minimumColdReviewRepositoriesPerRefresh)
        self.now = now
    }

    public func load(
        profile: GitHubConnectionProfile,
        inventory: GitHubAccessInventory,
        capabilities: GitHubConnectionCapabilityAssessment? = nil
    ) async -> GitHubActivityLoadResult {
        guard profile.isEnabled else {
            reset(connectionID: profile.id)
            return .empty
        }

        if loadsInProgress.contains(profile.id) {
            return lastResultByConnectionID[profile.id] ?? .empty
        }

        let repositories = monitoredRepositories(
            selection: profile.repositorySelection,
            inventory: inventory
        )
        pruneState(connectionID: profile.id, repositories: repositories)

        guard !repositories.isEmpty else {
            lastResultByConnectionID[profile.id] = .empty
            return .empty
        }

        let workflowBlocked = blockedRepositories(
            repositories,
            capability: .actions,
            capabilities: capabilities
        )
        let workflowBlockedIDs = Set(workflowBlocked.map(\.id))
        let workflowEligible = repositories.filter { !workflowBlockedIDs.contains($0.id) }
        removeWorkflowState(connectionID: profile.id, repositoryIDs: workflowBlockedIDs)

        let reviewBlocked: [GitHubRepositoryAccess]
        let reviewEligible: [GitHubRepositoryAccess]
        if reviewRequestLoader != nil {
            reviewBlocked = blockedRepositories(
                repositories,
                capability: .pullRequests,
                capabilities: capabilities
            )
            let blockedIDs = Set(reviewBlocked.map(\.id))
            reviewEligible = repositories.filter { !blockedIDs.contains($0.id) }
            removeReviewState(connectionID: profile.id, repositoryIDs: blockedIDs)
        } else {
            reviewBlocked = []
            reviewEligible = []
        }

        let checkBlocked: [GitHubRepositoryAccess]
        let checkEligible: [GitHubRepositoryAccess]
        if checkRunLoader != nil {
            checkBlocked = blockedRepositories(
                repositories,
                capability: .checks,
                capabilities: capabilities
            )
            let blockedIDs = Set(checkBlocked.map(\.id))
            checkEligible = repositories.filter { !blockedIDs.contains($0.id) }
            removeCheckState(connectionID: profile.id, repositoryIDs: blockedIDs)
        } else {
            checkBlocked = []
            checkEligible = []
        }

        let timestamp = now()
        let workflowSelection = repositorySelectionForRefresh(
            connectionID: profile.id,
            repositories: workflowEligible,
            state: workflowPollState,
            maximumPerRefresh: maximumRepositoriesPerRefresh,
            minimumColdPerRefresh: minimumColdRepositoriesPerRefresh,
            timestamp: timestamp
        )
        workflowPollState = workflowSelection.state

        let reviewSelection: RepositoryRefreshSelection
        if reviewRequestLoader != nil {
            reviewSelection = repositorySelectionForRefresh(
                connectionID: profile.id,
                repositories: reviewEligible,
                state: reviewPollState,
                maximumPerRefresh: maximumReviewRepositoriesPerRefresh,
                minimumColdPerRefresh: minimumColdReviewRepositoriesPerRefresh,
                timestamp: timestamp
            )
            reviewPollState = reviewSelection.state
        } else {
            reviewSelection = RepositoryRefreshSelection(repositories: [], state: reviewPollState)
        }

        let generation = generationByConnectionID[profile.id, default: 0]
        loadsInProgress.insert(profile.id)
        defer { loadsInProgress.remove(profile.id) }

        let workflowOutcomes = await loadWorkflowRepositories(
            workflowSelection.repositories,
            profile: profile
        )
        let reviewOutcomes = await loadReviewRepositories(
            reviewSelection.repositories,
            profile: profile
        )

        guard generationByConnectionID[profile.id, default: 0] == generation else {
            return lastResultByConnectionID[profile.id] ?? .empty
        }

        var workflowFailures = blockedFailures(surface: .workflows, repositories: workflowBlocked)
        var reviewFailures = blockedFailures(surface: .reviewRequests, repositories: reviewBlocked)
        var successfulWorkflowCount = 0
        var successfulReviewCount = 0
        var recoveryEvents: [DeliveryRecoveryEvent] = []

        for outcome in workflowOutcomes {
            switch outcome {
            case let .success(repository, activities, evidence, runs):
                successfulWorkflowCount += 1
                let key = RepositoryPollKey(
                    connectionID: profile.id,
                    repositoryID: repository.id
                )
                cachedWorkflowActivities[key] = activities
                workflowEvidence[key] = evidence
                workflowPollState[key, default: RepositoryPollState()].isHot = !activities.isEmpty

                var tracker = workflowRecoveryTrackers[key]
                    ?? GitHubWorkflowRecoveryTracker()
                recoveryEvents.append(
                    contentsOf: tracker.observe(
                        runs: runs,
                        repository: repository
                    )
                )
                workflowRecoveryTrackers[key] = tracker

            case let .failure(failure):
                workflowFailures.append(failure)
            }
        }

        for outcome in reviewOutcomes {
            switch outcome {
            case let .success(repositoryID, requests):
                successfulReviewCount += 1
                let key = RepositoryPollKey(connectionID: profile.id, repositoryID: repositoryID)
                cachedReviewRequests[key] = requests
                reviewPollState[key, default: RepositoryPollState()].isHot = !requests.isEmpty
            case let .failure(failure):
                reviewFailures.append(failure)
            }
        }

        let repositoryByID = Dictionary(uniqueKeysWithValues: repositories.map { ($0.id, $0) })
        let reviewRequestsByRepositoryID = Dictionary(
            uniqueKeysWithValues: checkEligible.map { repository in
                let key = RepositoryPollKey(connectionID: profile.id, repositoryID: repository.id)
                return (repository.id, cachedReviewRequests[key, default: []])
            }
        )
        let workflowEvidenceByRepositoryID = Dictionary(
            uniqueKeysWithValues: checkEligible.map { repository in
                let key = RepositoryPollKey(connectionID: profile.id, repositoryID: repository.id)
                return (repository.id, workflowEvidence[key, default: []])
            }
        )

        let checkCandidates: [GitHubCheckCandidate]
        if checkRunLoader != nil {
            checkCandidates = checkCandidatePlanner.candidates(
                repositories: checkEligible,
                reviewRequestsByRepositoryID: reviewRequestsByRepositoryID,
                workflowEvidenceByRepositoryID: workflowEvidenceByRepositoryID,
                maximumTotal: maximumCheckTargetsPerRefresh,
                maximumPerRepository: maximumCheckTargetsPerRepository
            )
            let validCandidateKeys = Set(checkCandidates.map {
                CheckPollKey(
                    connectionID: profile.id,
                    repositoryID: $0.repositoryID,
                    headSHA: $0.headSHA
                )
            })
            pruneCheckCandidates(
                connectionID: profile.id,
                validCandidateKeys: validCandidateKeys
            )
        } else {
            checkCandidates = []
        }

        let visibleWorkflowSHAsByRepositoryID = Dictionary(
            uniqueKeysWithValues: checkEligible.map { repository in
                let key = RepositoryPollKey(connectionID: profile.id, repositoryID: repository.id)
                let visible = Set(
                    workflowEvidence[key, default: []]
                        .filter(\.isVisible)
                        .map(\.headSHA)
                )
                return (repository.id, visible)
            }
        )

        let checkOutcomes = await loadCheckCandidates(
            checkCandidates,
            repositoryByID: repositoryByID,
            visibleWorkflowSHAsByRepositoryID: visibleWorkflowSHAsByRepositoryID,
            profile: profile
        )

        guard generationByConnectionID[profile.id, default: 0] == generation else {
            return lastResultByConnectionID[profile.id] ?? .empty
        }

        var checkFailures = blockedFailures(surface: .checks, repositories: checkBlocked)
        var successfulCheckCount = 0
        for outcome in checkOutcomes {
            switch outcome {
            case let .success(key, activities):
                successfulCheckCount += 1
                cachedCheckActivities[key] = activities
            case let .failure(_, failure):
                checkFailures.append(failure)
            }
        }

        let surfaces: [GitHubActivitySurface: GitHubActivitySurfaceResult] = [
            .workflows: GitHubActivitySurfaceResult(
                surface: .workflows,
                items: workflowItems(connectionID: profile.id),
                failures: workflowFailures,
                successfulTargetCount: successfulWorkflowCount,
                attemptedTargetCount: workflowSelection.repositories.count,
                blockedTargetCount: workflowBlocked.count
            ),
            .reviewRequests: GitHubActivitySurfaceResult(
                surface: .reviewRequests,
                items: reviewItems(connectionID: profile.id, repositoryByID: repositoryByID),
                failures: reviewFailures,
                successfulTargetCount: successfulReviewCount,
                attemptedTargetCount: reviewSelection.repositories.count,
                blockedTargetCount: reviewBlocked.count
            ),
            .checks: GitHubActivitySurfaceResult(
                surface: .checks,
                items: checkItems(connectionID: profile.id),
                failures: checkFailures,
                successfulTargetCount: successfulCheckCount,
                attemptedTargetCount: checkCandidates.count,
                blockedTargetCount: checkBlocked.count
            ),
        ]

        let result = GitHubActivityLoadResult(
            surfaces: surfaces,
            recoveryEvents: recoveryEvents
        )
        lastResultByConnectionID[profile.id] = result.droppingRecoveryEvents()
        return result
    }

    public func reset(connectionID: UUID) {
        generationByConnectionID[connectionID, default: 0] &+= 1
        workflowPollState = workflowPollState.filter { $0.key.connectionID != connectionID }
        reviewPollState = reviewPollState.filter { $0.key.connectionID != connectionID }
        cachedWorkflowActivities = cachedWorkflowActivities.filter { $0.key.connectionID != connectionID }
        workflowEvidence = workflowEvidence.filter { $0.key.connectionID != connectionID }
        workflowRecoveryTrackers = workflowRecoveryTrackers.filter {
            $0.key.connectionID != connectionID
        }
        cachedReviewRequests = cachedReviewRequests.filter { $0.key.connectionID != connectionID }
        cachedCheckActivities = cachedCheckActivities.filter { $0.key.connectionID != connectionID }
        lastResultByConnectionID.removeValue(forKey: connectionID)
        loadsInProgress.remove(connectionID)
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

    private func blockedRepositories(
        _ repositories: [GitHubRepositoryAccess],
        capability: GitHubCapability,
        capabilities: GitHubConnectionCapabilityAssessment?
    ) -> [GitHubRepositoryAccess] {
        repositories.filter { repository in
            guard let state = capabilities?.state(
                for: capability,
                repositoryID: repository.id
            ) else {
                return false
            }
            if case .unavailable = state {
                return true
            }
            return false
        }
    }

    private func blockedFailures(
        surface: GitHubActivitySurface,
        repositories: [GitHubRepositoryAccess]
    ) -> [GitHubActivityTargetFailure] {
        repositories.map {
            GitHubActivityTargetFailure(
                surface: surface,
                repositoryID: $0.id,
                repositoryFullName: $0.fullName,
                reason: .capabilityUnavailable
            )
        }
    }

    private func repositorySelectionForRefresh(
        connectionID: UUID,
        repositories: [GitHubRepositoryAccess],
        state: [RepositoryPollKey: RepositoryPollState],
        maximumPerRefresh: Int,
        minimumColdPerRefresh: Int,
        timestamp: Date
    ) -> RepositoryRefreshSelection {
        let budget = min(maximumPerRefresh, repositories.count)
        guard budget > 0 else {
            return RepositoryRefreshSelection(repositories: [], state: state)
        }

        var updatedState = state
        let hot = repositories
            .filter {
                updatedState[
                    RepositoryPollKey(connectionID: connectionID, repositoryID: $0.id)
                ]?.isHot == true
            }
            .sorted {
                pollCandidateSort(
                    lhs: $0,
                    rhs: $1,
                    connectionID: connectionID,
                    state: updatedState
                )
            }
        let cold = repositories
            .filter {
                updatedState[
                    RepositoryPollKey(connectionID: connectionID, repositoryID: $0.id)
                ]?.isHot != true
            }
            .sorted {
                pollCandidateSort(
                    lhs: $0,
                    rhs: $1,
                    connectionID: connectionID,
                    state: updatedState
                )
            }

        let reservedCold = min(minimumColdPerRefresh, cold.count, budget)
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
            let key = RepositoryPollKey(connectionID: connectionID, repositoryID: repository.id)
            updatedState[key, default: RepositoryPollState()].lastPolledAt = timestamp
        }
        return RepositoryRefreshSelection(repositories: selected, state: updatedState)
    }

    private func pollCandidateSort(
        lhs: GitHubRepositoryAccess,
        rhs: GitHubRepositoryAccess,
        connectionID: UUID,
        state: [RepositoryPollKey: RepositoryPollState]
    ) -> Bool {
        let lhsKey = RepositoryPollKey(connectionID: connectionID, repositoryID: lhs.id)
        let rhsKey = RepositoryPollKey(connectionID: connectionID, repositoryID: rhs.id)
        let lhsDate = state[lhsKey]?.lastPolledAt
        let rhsDate = state[rhsKey]?.lastPolledAt

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
        workflowPollState = workflowPollState.filter { key, _ in
            key.connectionID != connectionID || validRepositoryIDs.contains(key.repositoryID)
        }
        reviewPollState = reviewPollState.filter { key, _ in
            key.connectionID != connectionID || validRepositoryIDs.contains(key.repositoryID)
        }
        cachedWorkflowActivities = cachedWorkflowActivities.filter { key, _ in
            key.connectionID != connectionID || validRepositoryIDs.contains(key.repositoryID)
        }
        workflowEvidence = workflowEvidence.filter { key, _ in
            key.connectionID != connectionID || validRepositoryIDs.contains(key.repositoryID)
        }
        workflowRecoveryTrackers = workflowRecoveryTrackers.filter { key, _ in
            key.connectionID != connectionID || validRepositoryIDs.contains(key.repositoryID)
        }
        cachedReviewRequests = cachedReviewRequests.filter { key, _ in
            key.connectionID != connectionID || validRepositoryIDs.contains(key.repositoryID)
        }
        cachedCheckActivities = cachedCheckActivities.filter { key, _ in
            key.connectionID != connectionID || validRepositoryIDs.contains(key.repositoryID)
        }
    }

    private func removeWorkflowState(
        connectionID: UUID,
        repositoryIDs: Set<Int64>
    ) {
        guard !repositoryIDs.isEmpty else { return }
        workflowPollState = workflowPollState.filter { key, _ in
            key.connectionID != connectionID || !repositoryIDs.contains(key.repositoryID)
        }
        cachedWorkflowActivities = cachedWorkflowActivities.filter { key, _ in
            key.connectionID != connectionID || !repositoryIDs.contains(key.repositoryID)
        }
        workflowEvidence = workflowEvidence.filter { key, _ in
            key.connectionID != connectionID || !repositoryIDs.contains(key.repositoryID)
        }
    }

    private func removeReviewState(
        connectionID: UUID,
        repositoryIDs: Set<Int64>
    ) {
        guard !repositoryIDs.isEmpty else { return }
        reviewPollState = reviewPollState.filter { key, _ in
            key.connectionID != connectionID || !repositoryIDs.contains(key.repositoryID)
        }
        cachedReviewRequests = cachedReviewRequests.filter { key, _ in
            key.connectionID != connectionID || !repositoryIDs.contains(key.repositoryID)
        }
    }

    private func removeCheckState(
        connectionID: UUID,
        repositoryIDs: Set<Int64>
    ) {
        guard !repositoryIDs.isEmpty else { return }
        cachedCheckActivities = cachedCheckActivities.filter { key, _ in
            key.connectionID != connectionID || !repositoryIDs.contains(key.repositoryID)
        }
    }

    private func pruneCheckCandidates(
        connectionID: UUID,
        validCandidateKeys: Set<CheckPollKey>
    ) {
        cachedCheckActivities = cachedCheckActivities.filter { key, _ in
            key.connectionID != connectionID || validCandidateKeys.contains(key)
        }
    }

    private func loadWorkflowRepositories(
        _ repositories: [GitHubRepositoryAccess],
        profile: GitHubConnectionProfile
    ) async -> [WorkflowLoadOutcome] {
        let loader = workflowRunLoader
        let mapper = activityMapper
        let supersessionResolver = workflowRunSupersessionResolver
        let runLimit = perRepositoryRunLimit
        let maximumConcurrentRepositories = maximumConcurrentRepositories

        let loadOne: @Sendable (GitHubRepositoryAccess) async -> WorkflowLoadOutcome = { repository in
            do {
                let runs = try await loader.workflowRuns(
                    connection: profile.connection,
                    identity: profile.account,
                    clientID: profile.clientID,
                    repository: repository,
                    query: GitHubWorkflowRunQuery(limit: runLimit)
                )
                let currentRuns = supersessionResolver.resolve(runs: runs).currentRuns
                let activities = mapper.visibleActivities(runs: currentRuns, repository: repository)
                let visibleRunIDs = Set(activities.map(\.workflowRunID))
                let evidence = currentRuns.compactMap { run -> GitHubWorkflowEvidence? in
                    let headSHA = run.headSHA
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                        .lowercased()
                    guard !headSHA.isEmpty else { return nil }
                    return GitHubWorkflowEvidence(
                        repositoryID: repository.id,
                        headSHA: headSHA,
                        classification: mapper.classification(for: run),
                        updatedAt: run.updatedAt,
                        isVisible: visibleRunIDs.contains(run.id)
                    )
                }
                return .success(
                    repository: repository,
                    activities: activities,
                    evidence: evidence,
                    runs: currentRuns
                )
            } catch {
                return .failure(
                    GitHubActivityTargetFailure(
                        surface: .workflows,
                        repositoryID: repository.id,
                        repositoryFullName: repository.fullName,
                        reason: Self.failureReason(for: error)
                    )
                )
            }
        }

        return await boundedLoad(
            repositories,
            maximumConcurrent: maximumConcurrentRepositories,
            loadOne: loadOne
        )
    }

    private func loadReviewRepositories(
        _ repositories: [GitHubRepositoryAccess],
        profile: GitHubConnectionProfile
    ) async -> [ReviewLoadOutcome] {
        guard let loader = reviewRequestLoader else { return [] }
        let mapper = reviewRequestMapper
        let maximumConcurrentRepositories = maximumConcurrentRepositories

        let loadOne: @Sendable (GitHubRepositoryAccess) async -> ReviewLoadOutcome = { repository in
            do {
                let requests = try await loader.reviewRequests(
                    connection: profile.connection,
                    identity: profile.account,
                    clientID: profile.clientID,
                    repository: repository
                )
                let directRequests = mapper.visibleRequests(
                    requests: requests,
                    identity: profile.account
                )
                return .success(repositoryID: repository.id, requests: directRequests)
            } catch {
                return .failure(
                    GitHubActivityTargetFailure(
                        surface: .reviewRequests,
                        repositoryID: repository.id,
                        repositoryFullName: repository.fullName,
                        reason: Self.failureReason(for: error)
                    )
                )
            }
        }

        return await boundedLoad(
            repositories,
            maximumConcurrent: maximumConcurrentRepositories,
            loadOne: loadOne
        )
    }

    private func loadCheckCandidates(
        _ candidates: [GitHubCheckCandidate],
        repositoryByID: [Int64: GitHubRepositoryAccess],
        visibleWorkflowSHAsByRepositoryID: [Int64: Set<String>],
        profile: GitHubConnectionProfile
    ) async -> [CheckLoadOutcome] {
        guard let loader = checkRunLoader else { return [] }
        let mapper = checkRunMapper
        let maximumConcurrentRepositories = maximumConcurrentRepositories

        let targets = candidates.compactMap { candidate -> CheckLoadTarget? in
            guard let repository = repositoryByID[candidate.repositoryID] else { return nil }
            return CheckLoadTarget(candidate: candidate, repository: repository)
        }
        let loadOne: @Sendable (CheckLoadTarget) async -> CheckLoadOutcome = { target in
            let key = CheckPollKey(
                connectionID: profile.id,
                repositoryID: target.repository.id,
                headSHA: target.candidate.headSHA
            )
            do {
                let checks = try await loader.checkRuns(
                    connection: profile.connection,
                    identity: profile.account,
                    clientID: profile.clientID,
                    repository: target.repository,
                    headSHA: target.candidate.headSHA
                )
                let activities = mapper.visibleActivities(
                    checks: checks,
                    repository: target.repository,
                    visibleWorkflowSHAs: visibleWorkflowSHAsByRepositoryID[target.repository.id, default: []]
                )
                return .success(key: key, activities: activities)
            } catch {
                return .failure(
                    key: key,
                    failure: GitHubActivityTargetFailure(
                        surface: .checks,
                        repositoryID: target.repository.id,
                        repositoryFullName: target.repository.fullName,
                        reason: Self.failureReason(for: error)
                    )
                )
            }
        }

        return await boundedLoad(
            targets,
            maximumConcurrent: maximumConcurrentRepositories,
            loadOne: loadOne
        )
    }

    private func boundedLoad<Element: Sendable, Outcome: Sendable>(
        _ elements: [Element],
        maximumConcurrent: Int,
        loadOne: @escaping @Sendable (Element) async -> Outcome
    ) async -> [Outcome] {
        await withTaskGroup(of: Outcome.self) { group in
            var iterator = elements.makeIterator()
            var activeTasks = 0

            while activeTasks < maximumConcurrent,
                  let element = iterator.next()
            {
                group.addTask { await loadOne(element) }
                activeTasks += 1
            }

            var outcomes: [Outcome] = []
            outcomes.reserveCapacity(elements.count)
            while let outcome = await group.next() {
                outcomes.append(outcome)
                activeTasks -= 1
                if let element = iterator.next() {
                    group.addTask { await loadOne(element) }
                    activeTasks += 1
                }
            }
            return outcomes
        }
    }

    private func workflowItems(connectionID: UUID) -> [ActivityItem] {
        cachedWorkflowActivities
            .filter { $0.key.connectionID == connectionID }
            .values
            .flatMap { $0 }
            .map(makeActivityItem)
            .sorted(by: ActivityInboxOrdering().areInIncreasingOrder)
    }

    private func reviewItems(
        connectionID: UUID,
        repositoryByID: [Int64: GitHubRepositoryAccess]
    ) -> [ActivityItem] {
        cachedReviewRequests
            .filter { $0.key.connectionID == connectionID }
            .flatMap { key, requests -> [ActivityItem] in
                guard let repository = repositoryByID[key.repositoryID] else { return [] }
                return requests.map {
                    reviewRequestMapper.activityItem(request: $0, repository: repository)
                }
            }
            .sorted(by: ActivityInboxOrdering().areInIncreasingOrder)
    }

    private func checkItems(connectionID: UUID) -> [ActivityItem] {
        cachedCheckActivities
            .filter { $0.key.connectionID == connectionID }
            .values
            .flatMap { $0 }
            .sorted(by: ActivityInboxOrdering().areInIncreasingOrder)
    }

    private func makeActivityItem(_ activity: GitHubWorkflowActivity) -> ActivityItem {
        ActivityItem(
            id: activity.id,
            repository: activity.repositoryFullName,
            context: activity.context,
            detail: activity.detail,
            state: activityState(activity.classification),
            destinationURL: activity.webURL,
            kind: .workflowRun,
            updatedAt: activity.updatedAt
        )
    }

    private func activityState(
        _ classification: GitHubWorkflowActivityClassification
    ) -> ActivityState {
        switch classification {
        case .waiting: .waiting
        case .running: .running
        case .success: .success
        case .failed: .failed
        case .ignored: .waiting
        }
    }

    private static func failureReason(
        for error: Error
    ) -> GitHubRepositoryActivityFailureReason {
        switch error {
        case GitHubConnectionSessionError.credentialNotFound,
             GitHubConnectionSessionError.reauthenticationRequired,
             GitHubConnectionSessionError.accountMismatch(_, _),
             GitHubActionsClientError.httpStatus(401),
             GitHubPullRequestListClientError.httpStatus(401),
             GitHubCheckRunClientError.httpStatus(401):
            return .authenticationRequired

        case GitHubActionsClientError.httpStatus(403),
             GitHubPullRequestListClientError.httpStatus(403),
             GitHubCheckRunClientError.httpStatus(403):
            return .forbidden

        case GitHubActionsClientError.httpStatus(404),
             GitHubPullRequestListClientError.httpStatus(404),
             GitHubCheckRunClientError.httpStatus(404):
            return .notFound

        case let error where GitHubNetworkFailureClassifier.isUnavailable(error):
            return .networkUnavailable

        default:
            return .unavailable
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
}

private struct RepositoryPollKey: Hashable, Sendable {
    let connectionID: UUID
    let repositoryID: Int64
}

private struct CheckPollKey: Hashable, Sendable {
    let connectionID: UUID
    let repositoryID: Int64
    let headSHA: String
}

private struct RepositoryPollState: Sendable {
    var lastPolledAt: Date?
    var isHot = false
}

private struct RepositoryRefreshSelection: Sendable {
    let repositories: [GitHubRepositoryAccess]
    let state: [RepositoryPollKey: RepositoryPollState]
}

private struct CheckLoadTarget: Sendable {
    let candidate: GitHubCheckCandidate
    let repository: GitHubRepositoryAccess
}

private enum WorkflowLoadOutcome: Sendable {
    case success(
        repository: GitHubRepositoryAccess,
        activities: [GitHubWorkflowActivity],
        evidence: [GitHubWorkflowEvidence],
        runs: [GitHubWorkflowRun]
    )
    case failure(GitHubActivityTargetFailure)
}

private enum ReviewLoadOutcome: Sendable {
    case success(repositoryID: Int64, requests: [GitHubReviewRequest])
    case failure(GitHubActivityTargetFailure)
}

private enum CheckLoadOutcome: Sendable {
    case success(key: CheckPollKey, activities: [ActivityItem])
    case failure(key: CheckPollKey, failure: GitHubActivityTargetFailure)
}

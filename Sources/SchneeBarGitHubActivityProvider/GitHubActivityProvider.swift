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
    private let cachePolicy: GitHubActivityCachePolicy
    private let now: @Sendable () -> Date

    private var workflowPollState: [RepositoryPollKey: RepositoryPollState] = [:]
    private var reviewPollState: [RepositoryPollKey: RepositoryPollState] = [:]
    private var nextRepositoryPollSequence: UInt64 = 0
    private var checkPollSequenceByRepository: [RepositoryPollKey: UInt64] = [:]
    private var nextCheckPollSequence: UInt64 = 0
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
        cachePolicy: GitHubActivityCachePolicy = .init(),
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
        self.cachePolicy = cachePolicy
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
            minimumColdPerRefresh: minimumColdRepositoriesPerRefresh
        )
        workflowPollState = workflowSelection.state

        let reviewSelection: RepositoryRefreshSelection
        if reviewRequestLoader != nil {
            reviewSelection = repositorySelectionForRefresh(
                connectionID: profile.id,
                repositories: reviewEligible,
                state: reviewPollState,
                maximumPerRefresh: maximumReviewRepositoriesPerRefresh,
                minimumColdPerRefresh: minimumColdReviewRepositoriesPerRefresh
            )
            reviewPollState = reviewSelection.state
        } else {
            reviewSelection = RepositoryRefreshSelection(repositories: [], state: reviewPollState)
        }

        let generation = generationByConnectionID[profile.id, default: 0]
        loadsInProgress.insert(profile.id)
        defer { loadsInProgress.remove(profile.id) }

        let workflowBatch = await loadWorkflowRepositories(
            workflowSelection.repositories,
            profile: profile
        )
        let workflowOutcomes = workflowBatch.outcomes
        workflowPollState = stateRecordingPollAttempts(
            connectionID: profile.id,
            repositoryIDs: workflowSelection.repositories
                .map(\.id)
                .filter(workflowBatch.attempts.contains),
            timestamp: timestamp,
            state: workflowPollState
        )
        guard !Task.isCancelled else {
            return lastResultByConnectionID[profile.id] ?? .empty
        }

        let reviewBatch = await loadReviewRepositories(
            reviewSelection.repositories,
            profile: profile
        )
        let reviewOutcomes = reviewBatch.outcomes
        reviewPollState = stateRecordingPollAttempts(
            connectionID: profile.id,
            repositoryIDs: reviewSelection.repositories
                .map(\.id)
                .filter(reviewBatch.attempts.contains),
            timestamp: timestamp,
            state: reviewPollState
        )
        guard !Task.isCancelled else {
            return lastResultByConnectionID[profile.id] ?? .empty
        }

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
                if activities.isEmpty {
                    cachedWorkflowActivities.removeValue(forKey: key)
                } else {
                    cachedWorkflowActivities[key] = activities
                }
                if evidence.isEmpty {
                    workflowEvidence.removeValue(forKey: key)
                } else {
                    workflowEvidence[key] = evidence
                }
                workflowPollState[key, default: RepositoryPollState()].isHot = !activities.isEmpty

                var tracker = workflowRecoveryTrackers[key]
                    ?? GitHubWorkflowRecoveryTracker(
                        maximumLanes:
                            cachePolicy.maximumRecoveryLanesPerRepository
                    )
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
                if requests.isEmpty {
                    cachedReviewRequests.removeValue(forKey: key)
                } else {
                    cachedReviewRequests[key] = requests
                }
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
            let orderedCheckRepositories = checkEligible.sorted {
                checkCandidateSort(
                    lhs: $0,
                    rhs: $1,
                    connectionID: profile.id
                )
            }
            checkCandidates = checkCandidatePlanner.candidates(
                repositories: orderedCheckRepositories,
                reviewRequestsByRepositoryID: reviewRequestsByRepositoryID,
                workflowEvidenceByRepositoryID: workflowEvidenceByRepositoryID,
                maximumTotal: maximumCheckTargetsPerRefresh,
                maximumPerRepository: maximumCheckTargetsPerRepository
            )
            let validCandidateKeys = validCachedCheckCandidateKeys(
                connectionID: profile.id,
                repositories: checkEligible,
                reviewRequestsByRepositoryID: reviewRequestsByRepositoryID,
                workflowEvidenceByRepositoryID: workflowEvidenceByRepositoryID
            )
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

        let checkBatch = await loadCheckCandidates(
            checkCandidates,
            repositoryByID: repositoryByID,
            visibleWorkflowSHAsByRepositoryID: visibleWorkflowSHAsByRepositoryID,
            profile: profile
        )
        let checkOutcomes = checkBatch.outcomes
        recordCheckPollAttempts(
            connectionID: profile.id,
            candidates: checkCandidates,
            attemptedKeys: checkBatch.attempts
        )
        guard !Task.isCancelled else {
            return lastResultByConnectionID[profile.id] ?? .empty
        }

        guard generationByConnectionID[profile.id, default: 0] == generation else {
            return lastResultByConnectionID[profile.id] ?? .empty
        }

        var checkFailures = blockedFailures(surface: .checks, repositories: checkBlocked)
        var successfulCheckCount = 0
        for outcome in checkOutcomes {
            switch outcome {
            case let .success(key, activities):
                successfulCheckCount += 1
                if activities.isEmpty {
                    cachedCheckActivities.removeValue(forKey: key)
                } else {
                    cachedCheckActivities[key] = activities
                }
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
        enforceRetainedCacheBudget(connectionID: profile.id)
        lastResultByConnectionID[profile.id] = result.boundedForRetention(
            maximumItemsPerSurface:
                cachePolicy.maximumRetainedItemsPerSurface,
            maximumFailuresPerSurface:
                cachePolicy.maximumRetainedFailuresPerSurface
        )
        return result
    }

    public func reset(connectionID: UUID) {
        generationByConnectionID[connectionID, default: 0] &+= 1
        workflowPollState = workflowPollState.filter { $0.key.connectionID != connectionID }
        reviewPollState = reviewPollState.filter { $0.key.connectionID != connectionID }
        checkPollSequenceByRepository = checkPollSequenceByRepository.filter {
            $0.key.connectionID != connectionID
        }
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
        minimumColdPerRefresh: Int
    ) -> RepositoryRefreshSelection {
        let budget = min(maximumPerRefresh, repositories.count)
        guard budget > 0 else {
            return RepositoryRefreshSelection(repositories: [], state: state)
        }

        let updatedState = state
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

        return RepositoryRefreshSelection(repositories: selected, state: updatedState)
    }

    private func stateRecordingPollAttempts(
        connectionID: UUID,
        repositoryIDs: [Int64],
        timestamp: Date,
        state: [RepositoryPollKey: RepositoryPollState]
    ) -> [RepositoryPollKey: RepositoryPollState] {
        var updatedState = state
        for repositoryID in repositoryIDs {
            let key = RepositoryPollKey(
                connectionID: connectionID,
                repositoryID: repositoryID
            )
            updatedState[key, default: RepositoryPollState()].lastPolledAt = timestamp
            updatedState[key, default: RepositoryPollState()].lastPollSequence =
                nextRepositoryPollSequence
            nextRepositoryPollSequence &+= 1
        }
        return updatedState
    }

    private func recordCheckPollAttempts(
        connectionID: UUID,
        candidates: [GitHubCheckCandidate],
        attemptedKeys: Set<CheckPollKey>
    ) {
        for candidate in candidates {
            let candidateKey = CheckPollKey(
                connectionID: connectionID,
                repositoryID: candidate.repositoryID,
                headSHA: candidate.headSHA
            )
            guard attemptedKeys.contains(candidateKey) else {
                continue
            }

            let repositoryKey = RepositoryPollKey(
                connectionID: connectionID,
                repositoryID: candidate.repositoryID
            )
            checkPollSequenceByRepository[repositoryKey] = nextCheckPollSequence
            nextCheckPollSequence &+= 1
        }
    }

    private func checkCandidateSort(
        lhs: GitHubRepositoryAccess,
        rhs: GitHubRepositoryAccess,
        connectionID: UUID
    ) -> Bool {
        let lhsKey = RepositoryPollKey(connectionID: connectionID, repositoryID: lhs.id)
        let rhsKey = RepositoryPollKey(connectionID: connectionID, repositoryID: rhs.id)
        let lhsSequence = checkPollSequenceByRepository[lhsKey]
        let rhsSequence = checkPollSequenceByRepository[rhsKey]

        switch (lhsSequence, rhsSequence) {
        case (nil, nil):
            return repositorySort(lhs: lhs, rhs: rhs)
        case (nil, _):
            return true
        case (_, nil):
            return false
        case let (lhsSequence?, rhsSequence?):
            if lhsSequence != rhsSequence {
                return lhsSequence < rhsSequence
            }
            return repositorySort(lhs: lhs, rhs: rhs)
        }
    }

    private func pollCandidateSort(
        lhs: GitHubRepositoryAccess,
        rhs: GitHubRepositoryAccess,
        connectionID: UUID,
        state: [RepositoryPollKey: RepositoryPollState]
    ) -> Bool {
        let lhsKey = RepositoryPollKey(connectionID: connectionID, repositoryID: lhs.id)
        let rhsKey = RepositoryPollKey(connectionID: connectionID, repositoryID: rhs.id)
        let lhsSequence = state[lhsKey]?.lastPollSequence
        let rhsSequence = state[rhsKey]?.lastPollSequence

        switch (lhsSequence, rhsSequence) {
        case (nil, nil):
            return repositorySort(lhs: lhs, rhs: rhs)
        case (nil, _):
            return true
        case (_, nil):
            return false
        case let (lhsSequence?, rhsSequence?):
            if lhsSequence != rhsSequence {
                return lhsSequence < rhsSequence
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
        checkPollSequenceByRepository = checkPollSequenceByRepository.filter { key, _ in
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
        workflowRecoveryTrackers = workflowRecoveryTrackers.filter {
            key, _ in
            key.connectionID != connectionID
                || !repositoryIDs.contains(key.repositoryID)
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
        checkPollSequenceByRepository = checkPollSequenceByRepository.filter { key, _ in
            key.connectionID != connectionID || !repositoryIDs.contains(key.repositoryID)
        }
        cachedCheckActivities = cachedCheckActivities.filter { key, _ in
            key.connectionID != connectionID || !repositoryIDs.contains(key.repositoryID)
        }
    }

    private func validCachedCheckCandidateKeys(
        connectionID: UUID,
        repositories: [GitHubRepositoryAccess],
        reviewRequestsByRepositoryID: [Int64: [GitHubReviewRequest]],
        workflowEvidenceByRepositoryID: [Int64: [GitHubWorkflowEvidence]]
    ) -> Set<CheckPollKey> {
        let repositoryByID = Dictionary(
            uniqueKeysWithValues: repositories.map { ($0.id, $0) }
        )
        let cachedRepositoryIDs = Set(
            cachedCheckActivities.keys.compactMap { key in
                key.connectionID == connectionID
                    ? key.repositoryID
                    : nil
            }
        )

        var validKeys = Set<CheckPollKey>()
        for repositoryID in cachedRepositoryIDs {
            guard let repository = repositoryByID[repositoryID] else {
                continue
            }

            let candidates = checkCandidatePlanner.candidates(
                repository: repository,
                reviewRequests: reviewRequestsByRepositoryID[
                    repositoryID,
                    default: []
                ],
                workflowEvidence: workflowEvidenceByRepositoryID[
                    repositoryID,
                    default: []
                ],
                maximum: maximumCheckTargetsPerRepository
            )
            for candidate in candidates {
                validKeys.insert(
                    CheckPollKey(
                        connectionID: connectionID,
                        repositoryID: candidate.repositoryID,
                        headSHA: candidate.headSHA
                    )
                )
            }
        }
        return validKeys
    }

    private func pruneCheckCandidates(
        connectionID: UUID,
        validCandidateKeys: Set<CheckPollKey>
    ) {
        cachedCheckActivities = cachedCheckActivities.filter { key, _ in
            key.connectionID != connectionID || validCandidateKeys.contains(key)
        }
    }

    private func enforceRetainedCacheBudget(
        connectionID: UUID
    ) {
        let workflowKeys = Set(
            cachedWorkflowActivities.keys.filter {
                $0.connectionID == connectionID
            }
        )
        .union(
            workflowEvidence.keys.filter {
                $0.connectionID == connectionID
            }
        )
        .union(
            workflowRecoveryTrackers.keys.filter {
                $0.connectionID == connectionID
            }
        )
        let retainedWorkflowKeys = Set(
            workflowKeys.sorted {
                repositoryCacheKeyPrecedes(
                    lhs: $0,
                    rhs: $1,
                    state: workflowPollState
                )
            }
            .prefix(cachePolicy.maximumWorkflowRepositories)
        )
        for key in workflowKeys
        where !retainedWorkflowKeys.contains(key)
        {
            cachedWorkflowActivities.removeValue(forKey: key)
            workflowEvidence.removeValue(forKey: key)
            workflowRecoveryTrackers.removeValue(forKey: key)
        }

        let reviewKeys = Set(
            cachedReviewRequests.keys.filter {
                $0.connectionID == connectionID
            }
        )
        let retainedReviewKeys = Set(
            reviewKeys.sorted {
                repositoryCacheKeyPrecedes(
                    lhs: $0,
                    rhs: $1,
                    state: reviewPollState
                )
            }
            .prefix(cachePolicy.maximumReviewRepositories)
        )
        for key in reviewKeys
        where !retainedReviewKeys.contains(key)
        {
            cachedReviewRequests.removeValue(forKey: key)
        }

        let checkKeys = cachedCheckActivities.keys.filter {
            $0.connectionID == connectionID
        }
        let ordering = ActivityInboxOrdering()
        let bestItemByKey = Dictionary(
            uniqueKeysWithValues: checkKeys.map { key in
                (
                    key,
                    cachedCheckActivities[key]?
                        .sorted(by: ordering.areInIncreasingOrder)
                        .first
                )
            }
        )
        let retainedCheckKeys = Set(
            checkKeys.sorted { lhs, rhs in
                let lhsItem = bestItemByKey[lhs] ?? nil
                let rhsItem = bestItemByKey[rhs] ?? nil
                switch (lhsItem, rhsItem) {
                case let (lhsItem?, rhsItem?):
                    if ordering.areInIncreasingOrder(
                        lhsItem,
                        rhsItem
                    ) {
                        return true
                    }
                    if ordering.areInIncreasingOrder(
                        rhsItem,
                        lhsItem
                    ) {
                        return false
                    }
                case (_?, nil):
                    return true
                case (nil, _?):
                    return false
                case (nil, nil):
                    break
                }

                if lhs.repositoryID != rhs.repositoryID {
                    return lhs.repositoryID < rhs.repositoryID
                }
                return lhs.headSHA < rhs.headSHA
            }
            .prefix(cachePolicy.maximumCheckTargets)
        )
        for key in checkKeys
        where !retainedCheckKeys.contains(key)
        {
            cachedCheckActivities.removeValue(forKey: key)
        }
    }

    private func repositoryCacheKeyPrecedes(
        lhs: RepositoryPollKey,
        rhs: RepositoryPollKey,
        state: [RepositoryPollKey: RepositoryPollState]
    ) -> Bool {
        let lhsState = state[lhs]
        let rhsState = state[rhs]
        let lhsHot = lhsState?.isHot == true
        let rhsHot = rhsState?.isHot == true

        if lhsHot != rhsHot {
            return lhsHot
        }

        switch (
            lhsState?.lastPolledAt,
            rhsState?.lastPolledAt
        ) {
        case let (lhsDate?, rhsDate?):
            if lhsDate != rhsDate {
                return lhsDate > rhsDate
            }
        case (_?, nil):
            return true
        case (nil, _?):
            return false
        case (nil, nil):
            break
        }

        return lhs.repositoryID < rhs.repositoryID
    }

    private func loadWorkflowRepositories(
        _ repositories: [GitHubRepositoryAccess],
        profile: GitHubConnectionProfile
    ) async -> PollLoadBatch<WorkflowLoadOutcome, Int64> {
        let loader = workflowRunLoader
        let attempts = PollAttemptRecorder<Int64>()
        let mapper = activityMapper
        let supersessionResolver = workflowRunSupersessionResolver
        let runLimit = perRepositoryRunLimit
        let maximumConcurrentRepositories = maximumConcurrentRepositories

        let loadOne: @Sendable (GitHubRepositoryAccess) async -> WorkflowLoadOutcome = { repository in
            do {
                try Task.checkCancellation()
                await attempts.record(repository.id)
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

        let outcomes = await boundedLoad(
            repositories,
            maximumConcurrent: maximumConcurrentRepositories,
            loadOne: loadOne
        )
        return PollLoadBatch(
            outcomes: outcomes,
            attempts: await attempts.snapshot()
        )
    }

    private func loadReviewRepositories(
        _ repositories: [GitHubRepositoryAccess],
        profile: GitHubConnectionProfile
    ) async -> PollLoadBatch<ReviewLoadOutcome, Int64> {
        guard let loader = reviewRequestLoader else {
            return PollLoadBatch(outcomes: [], attempts: [])
        }
        let mapper = reviewRequestMapper
        let attempts = PollAttemptRecorder<Int64>()
        let maximumConcurrentRepositories = maximumConcurrentRepositories

        let loadOne: @Sendable (GitHubRepositoryAccess) async -> ReviewLoadOutcome = { repository in
            do {
                try Task.checkCancellation()
                await attempts.record(repository.id)
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

        let outcomes = await boundedLoad(
            repositories,
            maximumConcurrent: maximumConcurrentRepositories,
            loadOne: loadOne
        )
        return PollLoadBatch(
            outcomes: outcomes,
            attempts: await attempts.snapshot()
        )
    }

    private func loadCheckCandidates(
        _ candidates: [GitHubCheckCandidate],
        repositoryByID: [Int64: GitHubRepositoryAccess],
        visibleWorkflowSHAsByRepositoryID: [Int64: Set<String>],
        profile: GitHubConnectionProfile
    ) async -> PollLoadBatch<CheckLoadOutcome, CheckPollKey> {
        guard let loader = checkRunLoader else {
            return PollLoadBatch(outcomes: [], attempts: [])
        }
        let mapper = checkRunMapper
        let attempts = PollAttemptRecorder<CheckPollKey>()
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
                try Task.checkCancellation()
                await attempts.record(key)
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

        let outcomes = await boundedLoad(
            targets,
            maximumConcurrent: maximumConcurrentRepositories,
            loadOne: loadOne
        )
        return PollLoadBatch(
            outcomes: outcomes,
            attempts: await attempts.snapshot()
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

            while !Task.isCancelled,
                  activeTasks < maximumConcurrent,
                  let element = iterator.next()
            {
                group.addTask { await loadOne(element) }
                activeTasks += 1
            }

            if Task.isCancelled {
                group.cancelAll()
            }

            var outcomes: [Outcome] = []
            outcomes.reserveCapacity(elements.count)
            while let outcome = await group.next() {
                outcomes.append(outcome)
                activeTasks -= 1

                if Task.isCancelled {
                    group.cancelAll()
                    continue
                }

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
    var lastPollSequence: UInt64?
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


private struct PollLoadBatch<Outcome: Sendable, Attempt: Hashable & Sendable>: Sendable {
    let outcomes: [Outcome]
    let attempts: Set<Attempt>
}

private actor PollAttemptRecorder<Value: Hashable & Sendable> {
    private var values = Set<Value>()

    func record(_ value: Value) {
        values.insert(value)
    }

    func snapshot() -> Set<Value> {
        values
    }
}

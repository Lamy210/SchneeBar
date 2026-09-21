import Foundation
import Observation
import SchneeBarCore
import SchneeBarGitHub
import SchneeBarGitHubActivityProvider
import SchneeBarGitHubFeature

@MainActor
@Observable
final class GitHubConnectionsRuntimeModel {
    var profiles: [GitHubConnectionProfile] = []
    var statusByConnectionID: [UUID: GitHubConnectionPresentationStatus] = [:]
    var isPresentingOnboarding = false
    var onboardingDraft = GitHubConnectionDraft()
    var onboardingPhase: GitHubConnectionOnboardingPhase = .configuration
    var recoveringConnectionID: UUID?
    var recoveryPhase: GitHubConnectionRecoveryPhase = .requestingCode

    @ObservationIgnored
    var onActivitySourceChanged: (@MainActor @Sendable () -> Void)?

    @ObservationIgnored
    var onDeliveryRecovery:
        (@MainActor @Sendable (DeliveryRecoveryEvent) -> Void)?

    @ObservationIgnored
    private let profileStore: any GitHubConnectionProfileStore

    @ObservationIgnored
    private let sessionCoordinator: GitHubConnectionSessionCoordinator

    @ObservationIgnored
    private let activityProvider: GitHubActivityProvider

    @ObservationIgnored
    let deliveryHistoryStore: any DeliveryHistoryStoring

    @ObservationIgnored
    private let deviceFlowClient: GitHubDeviceFlowClient

    @ObservationIgnored
    private let authorizationWaiter: GitHubDeviceAuthorizationWaiter

    @ObservationIgnored
    private let enterpriseDiscovery: GitHubEnterpriseServerDiscoveryClient

    @ObservationIgnored
    private let enterpriseCompatibilityPolicy: GitHubEnterpriseCompatibilityPolicy

    @ObservationIgnored
    private let enterpriseMetadataRefreshPolicy: GitHubEnterpriseMetadataRefreshPolicy

    @ObservationIgnored
    private let now: @Sendable () -> Date

    @ObservationIgnored
    private var inventoryByConnectionID: [UUID: GitHubAccessInventory] = [:]

    @ObservationIgnored
    private var capabilitiesByConnectionID: [UUID: GitHubConnectionCapabilityAssessment] = [:]

    @ObservationIgnored
    private var onboardingTask: Task<Void, Never>?

    @ObservationIgnored
    private var recoveryTask: Task<Void, Never>?

    @ObservationIgnored
    private var operationGenerationByConnectionID: [UUID: UInt64] = [:]

    init(
        profileStore: any GitHubConnectionProfileStore,
        sessionCoordinator: GitHubConnectionSessionCoordinator,
        activityProvider: GitHubActivityProvider,
        deliveryHistoryStore: any DeliveryHistoryStoring = NoopDeliveryHistoryStore(),
        deviceFlowClient: GitHubDeviceFlowClient = GitHubDeviceFlowClient(),
        authorizationWaiter: GitHubDeviceAuthorizationWaiter = GitHubDeviceAuthorizationWaiter(),
        enterpriseDiscovery: GitHubEnterpriseServerDiscoveryClient = GitHubEnterpriseServerDiscoveryClient(),
        enterpriseCompatibilityPolicy: GitHubEnterpriseCompatibilityPolicy = .init(),
        enterpriseMetadataRefreshPolicy: GitHubEnterpriseMetadataRefreshPolicy = .init(),
        now: @escaping @Sendable () -> Date = { .now }
    ) {
        self.profileStore = profileStore
        self.sessionCoordinator = sessionCoordinator
        self.activityProvider = activityProvider
        self.deliveryHistoryStore = deliveryHistoryStore
        self.deviceFlowClient = deviceFlowClient
        self.authorizationWaiter = authorizationWaiter
        self.enterpriseDiscovery = enterpriseDiscovery
        self.enterpriseCompatibilityPolicy = enterpriseCompatibilityPolicy
        self.enterpriseMetadataRefreshPolicy = enterpriseMetadataRefreshPolicy
        self.now = now
    }

    var onboardingIsActive: Bool {
        switch onboardingPhase {
        case .requestingCode, .waitingForAuthorization, .finalizing:
            return true
        case .configuration, .failed:
            return false
        }
    }

    var recoveryContext: GitHubConnectionRecoveryContext? {
        guard let id = recoveringConnectionID,
              let profile = profiles.first(where: { $0.id == id })
        else {
            return nil
        }

        return GitHubConnectionRecoveryContext(
            connectionID: profile.id,
            displayName: profile.connection.displayName,
            host: displayHost(for: profile.connection),
            accountLogin: profile.account.login
        )
    }

    var recoveryIsActive: Bool {
        switch recoveryPhase {
        case .requestingCode, .waitingForAuthorization, .finalizing:
            return recoveringConnectionID != nil
        case .failed:
            return false
        }
    }

    var connectionCards: [GitHubConnectionCardModel] {
        GitHubConnectionProfileOrdering.sorted(profiles).map { profile in
            GitHubConnectionCardModel(
                id: profile.id,
                displayName: profile.connection.displayName,
                host: displayHost(for: profile.connection),
                accountLogin: profile.account.login,
                deploymentLabel: deploymentLabel(for: profile.connection),
                repositorySelectionLabel: repositorySelectionLabel(for: profile),
                status: statusByConnectionID[profile.id]
                    ?? (profile.isEnabled ? .syncing : .disabled),
                isEnabled: profile.isEnabled
            )
        }
    }

    func managementModel(profileID: UUID) -> GitHubConnectionManagementModel? {
        guard let profile = profiles.first(where: { $0.id == profileID }) else {
            return nil
        }

        let repositories = inventoryByConnectionID[profileID]
            .map(accessibleRepositories)
            ?? []
        let assessment = capabilitiesByConnectionID[profileID]

        return GitHubConnectionManagementModel(
            id: profile.id,
            displayName: profile.connection.displayName,
            host: displayHost(for: profile.connection),
            accountLogin: profile.account.login,
            repositories: repositories.map { repository in
                GitHubRepositoryOptionModel(
                    id: repository.id,
                    fullName: repository.fullName,
                    isPrivate: repository.isPrivate,
                    activityAccess: GitHubRepositoryActivityAccessModel(
                        actions: activityAccessPresentation(
                            assessment?.state(for: .actions, repositoryID: repository.id)
                        ),
                        reviewRequests: activityAccessPresentation(
                            assessment?.state(for: .pullRequests, repositoryID: repository.id)
                        ),
                        checks: activityAccessPresentation(
                            assessment?.state(for: .checks, repositoryID: repository.id)
                        ),
                        deployments: activityAccessPresentation(
                            assessment?.state(for: .deployments, repositoryID: repository.id)
                        )
                    )
                )
            }
        )
    }

    func repositorySelectionMode(
        profileID: UUID
    ) -> GitHubRepositorySelectionPresentationMode? {
        guard let profile = profiles.first(where: { $0.id == profileID }) else {
            return nil
        }

        switch profile.repositorySelection {
        case .allAccessible:
            return .allAccessible
        case .selected:
            return .selected
        }
    }

    func selectedRepositoryIDs(profileID: UUID) -> Set<Int64> {
        guard let profile = profiles.first(where: { $0.id == profileID }) else {
            return []
        }

        switch profile.repositorySelection {
        case .allAccessible:
            guard let inventory = inventoryByConnectionID[profileID] else {
                return []
            }
            return Set(accessibleRepositories(inventory).map(\.id))
        case let .selected(ids):
            return ids
        }
    }

    @discardableResult
    func saveRepositorySelection(
        profileID: UUID,
        mode: GitHubRepositorySelectionPresentationMode,
        selectedRepositoryIDs: Set<Int64>
    ) async -> Bool {
        guard var profile = profiles.first(where: { $0.id == profileID }) else {
            return false
        }

        switch mode {
        case .allAccessible:
            profile.repositorySelection = .allAccessible
        case .selected:
            profile.repositorySelection = .selected(selectedRepositoryIDs)
        }

        do {
            try await profileStore.save(profile)
            upsert(profile)
            await activityProvider.reset(connectionID: profileID)
            onActivitySourceChanged?()
            return true
        } catch {
            statusByConnectionID[profileID] = .unavailable
            return false
        }
    }

    func load() async {
        do {
            profiles = GitHubConnectionProfileOrdering.sorted(
                try await profileStore.loadAll()
            )
        } catch {
            profiles = []
            return
        }

        for profile in profiles {
            if profile.isEnabled {
                statusByConnectionID[profile.id] = .syncing
                Task { @MainActor [weak self] in
                    await self?.refresh(profileID: profile.id)
                }
            } else {
                statusByConnectionID[profile.id] = .disabled
            }
        }
    }

    func loadActivityItems() async throws -> [ActivityItem] {
        var items: [ActivityItem] = []
        var allFailures: [GitHubActivityTargetFailure] = []
        var attemptedTargetCount = 0
        var successfulTargetCount = 0

        let enabledProfiles = profiles.filter(\.isEnabled)
        for profile in enabledProfiles {
            guard let inventory = inventoryByConnectionID[profile.id] else {
                continue
            }

            let result = await activityProvider.load(
                profile: profile,
                inventory: inventory,
                capabilities: capabilitiesByConnectionID[profile.id]
            )

            guard let currentProfile = profiles.first(where: { $0.id == profile.id }),
                  currentProfile.isEnabled,
                  currentProfile.repositorySelection == profile.repositorySelection
            else {
                await activityProvider.reset(connectionID: profile.id)
                continue
            }

            attemptedTargetCount += result.attemptedTargetCount
            successfulTargetCount += result.successfulTargetCount
            allFailures.append(contentsOf: result.targetFailures)

            for recoveryEvent in result.recoveryEvents {
                onDeliveryRecovery?(recoveryEvent)
            }

            if result.targetFailures.contains(where: { $0.reason == .authenticationRequired }) {
                await activityProvider.reset(connectionID: profile.id)
                statusByConnectionID[profile.id] = .authenticationRequired
                continue
            }

            items.append(contentsOf: result.items)
            applyActivityStatus(
                result,
                profileID: profile.id,
                inventory: inventory,
                connection: profile.connection
            )
        }

        if attemptedTargetCount > 0,
           successfulTargetCount == 0
        {
            if allFailures.contains(where: { $0.reason == .authenticationRequired }) {
                throw RuntimeError.activityAuthenticationRequired
            }

            let operationalFailures = allFailures.filter {
                $0.reason != .capabilityUnavailable
            }
            let isTransientOutage = !operationalFailures.isEmpty
                && operationalFailures.allSatisfy {
                    $0.reason == .networkUnavailable || $0.reason == .unavailable
                }
            if isTransientOutage {
                throw RuntimeError.activityUnavailable
            }
        }

        return items.sorted(by: ActivityInboxOrdering().areInIncreasingOrder)
    }

    func beginOnboarding(defaultClientID: String? = nil) {
        cancelRecovery()
        onboardingTask?.cancel()
        onboardingDraft = GitHubConnectionDraft(clientID: defaultClientID ?? "")
        onboardingPhase = .configuration
        isPresentingOnboarding = true
    }

    func cancelOnboarding() {
        onboardingTask?.cancel()
        onboardingTask = nil
        onboardingPhase = .configuration
        isPresentingOnboarding = false
    }

    func connectDraft() {
        onboardingTask?.cancel()
        let draft = onboardingDraft

        onboardingTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                onboardingPhase = .requestingCode
                let connection = try await makeConnection(from: draft)
                let clientID = draft.clientID.trimmingCharacters(in: .whitespacesAndNewlines)
                let authorization = try await deviceFlowClient.begin(
                    connection: connection,
                    clientID: clientID
                )

                onboardingPhase = .waitingForAuthorization(
                    GitHubDeviceAuthorizationPresentation(
                        userCode: authorization.userCode,
                        verificationURI: authorization.verificationURI,
                        expiresAt: authorization.expiresAt
                    )
                )

                let credential = try await authorizationWaiter.waitForAuthorization(
                    connection: connection,
                    clientID: clientID,
                    session: authorization
                )
                try Task.checkCancellation()

                onboardingPhase = .finalizing
                let session = try await sessionCoordinator.establish(
                    connection: connection,
                    credential: credential
                )

                let now = Date.now
                let profile = GitHubConnectionProfileReconciler().reconcile(
                    existingProfiles: profiles,
                    authenticatedConnection: connection,
                    account: session.account.identity,
                    authenticationMethod: .deviceFlow,
                    clientID: clientID,
                    now: now
                )
                let previousProfile = profiles.first(where: { $0.id == profile.id })

                do {
                    try Task.checkCancellation()
                    try await profileStore.save(profile)
                } catch {
                    try? await sessionCoordinator.disconnect(
                        connection: connection,
                        identity: session.account.identity
                    )
                    throw error
                }

                var finalizedSession = session
                if profile.id != connection.id {
                    do {
                        finalizedSession = try await sessionCoordinator.rebindEstablishedSession(
                            session,
                            from: connection,
                            to: profile.connection
                        )
                    } catch {
                        if let previousProfile {
                            try? await profileStore.save(previousProfile)
                        }
                        try? await sessionCoordinator.disconnect(
                            connection: connection,
                            identity: session.account.identity
                        )
                        throw error
                    }
                }

                await activityProvider.reset(connectionID: profile.id)
                upsert(profile)
                if profile.isEnabled {
                    inventoryByConnectionID[profile.id] = finalizedSession.inventory
                    capabilitiesByConnectionID[profile.id] = finalizedSession.capabilities
                    statusByConnectionID[profile.id] = presentationStatus(
                        for: finalizedSession.inventory,
                        connection: profile.connection
                    )
                } else {
                    inventoryByConnectionID.removeValue(forKey: profile.id)
                    capabilitiesByConnectionID.removeValue(forKey: profile.id)
                    statusByConnectionID[profile.id] = .disabled
                }
                onActivitySourceChanged?()
                onboardingTask = nil
                onboardingPhase = .configuration
                isPresentingOnboarding = false
            } catch is CancellationError {
                onboardingTask = nil
            } catch {
                onboardingTask = nil
                onboardingPhase = .failed(message: errorMessage(for: error))
            }
        }
    }

    func beginRecovery(profileID: UUID) {
        guard profiles.contains(where: { $0.id == profileID }) else { return }
        cancelOnboarding()
        recoveringConnectionID = profileID
        startRecovery(profileID: profileID)
    }

    func retryRecovery() {
        guard let profileID = recoveringConnectionID else { return }
        startRecovery(profileID: profileID)
    }

    func cancelRecovery() {
        if let profileID = recoveringConnectionID {
            _ = advanceOperationGeneration(for: profileID)
        }
        recoveryTask?.cancel()
        recoveryTask = nil
        recoveringConnectionID = nil
        recoveryPhase = .requestingCode
    }

    func refresh(profileID: UUID) async {
        guard !(recoveringConnectionID == profileID && recoveryIsActive) else { return }
        guard var profile = profiles.first(where: { $0.id == profileID }) else { return }
        let generation = advanceOperationGeneration(for: profileID)

        guard profile.isEnabled else {
            guard isCurrentOperationGeneration(generation, for: profileID) else { return }
            let hadInventory = inventoryByConnectionID.removeValue(forKey: profileID) != nil
            capabilitiesByConnectionID.removeValue(forKey: profileID)
            await activityProvider.reset(connectionID: profileID)
            guard isCurrentOperationGeneration(generation, for: profileID) else { return }
            statusByConnectionID[profileID] = .disabled
            if hadInventory {
                onActivitySourceChanged?()
            }
            return
        }

        statusByConnectionID[profileID] = .syncing
        do {
            let profileBeforeMetadataRefresh = profile
            profile = try await refreshEnterpriseMetadataIfDue(
                profile,
                at: now()
            )
            guard isCurrentOperationGeneration(generation, for: profileID) else {
                return
            }

            if profile != profileBeforeMetadataRefresh {
                try? await profileStore.save(profile)
                try Task.checkCancellation()
                guard isCurrentOperationGeneration(generation, for: profileID) else {
                    await repairProfileStoreAfterStaleWrite(profileID: profileID)
                    return
                }
                upsert(profile)
            }

            let session = try await sessionCoordinator.restore(
                connection: profile.connection,
                identity: profile.account,
                clientID: profile.clientID
            )
            guard isCurrentOperationGeneration(generation, for: profileID) else { return }

            var updated = profile
            updated.lastConnectedAt = .now
            try await profileStore.save(updated)
            guard isCurrentOperationGeneration(generation, for: profileID) else {
                await repairProfileStoreAfterStaleWrite(profileID: profileID)
                return
            }

            inventoryByConnectionID[profileID] = session.inventory
            capabilitiesByConnectionID[profileID] = session.capabilities
            statusByConnectionID[profileID] = presentationStatus(
                for: session.inventory,
                connection: updated.connection
            )
            upsert(updated)
            onActivitySourceChanged?()
        } catch is CancellationError {
            return
        } catch GitHubConnectionSessionError.credentialNotFound,
                GitHubConnectionSessionError.reauthenticationRequired,
                GitHubConnectionSessionError.accountMismatch(_, _) {
            guard isCurrentOperationGeneration(generation, for: profileID) else { return }
            let hadInventory = inventoryByConnectionID.removeValue(forKey: profileID) != nil
            capabilitiesByConnectionID.removeValue(forKey: profileID)
            await activityProvider.reset(connectionID: profileID)
            guard isCurrentOperationGeneration(generation, for: profileID) else { return }
            statusByConnectionID[profileID] = .authenticationRequired
            if hadInventory {
                onActivitySourceChanged?()
            }
        } catch let error as URLError where error.code == .notConnectedToInternet
            || error.code == .cannotFindHost
            || error.code == .cannotConnectToHost
            || error.code == .dnsLookupFailed
            || error.code == .timedOut
        {
            guard isCurrentOperationGeneration(generation, for: profileID) else { return }
            statusByConnectionID[profileID] = .networkUnavailable
        } catch {
            guard isCurrentOperationGeneration(generation, for: profileID) else { return }
            statusByConnectionID[profileID] = .unavailable
        }
    }

    func setEnabled(_ isEnabled: Bool, profileID: UUID) {
        guard var profile = profiles.first(where: { $0.id == profileID }) else { return }
        _ = advanceOperationGeneration(for: profileID)
        profile.isEnabled = isEnabled
        upsert(profile)

        Task { [profileStore] in
            try? await profileStore.save(profile)
        }

        if isEnabled {
            statusByConnectionID[profileID] = .syncing
            Task { @MainActor [weak self] in
                await self?.refresh(profileID: profileID)
            }
        } else {
            let hadInventory = inventoryByConnectionID.removeValue(forKey: profileID) != nil
            capabilitiesByConnectionID.removeValue(forKey: profileID)
            let activityProvider = activityProvider
            Task {
                await activityProvider.reset(connectionID: profileID)
            }
            statusByConnectionID[profileID] = .disabled
            if hadInventory {
                onActivitySourceChanged?()
            }
        }
    }

    func disconnect(profileID: UUID) async {
        guard let profile = profiles.first(where: { $0.id == profileID }) else { return }
        _ = advanceOperationGeneration(for: profileID)
        if recoveringConnectionID == profileID {
            cancelRecovery()
        }

        do {
            try await sessionCoordinator.disconnect(
                connection: profile.connection,
                identity: profile.account
            )
            try await profileStore.delete(id: profileID)
            try? await deliveryHistoryStore.delete(
                sourceID: profileID.uuidString
            )
            profiles.removeAll(where: { $0.id == profileID })
            inventoryByConnectionID.removeValue(forKey: profileID)
            capabilitiesByConnectionID.removeValue(forKey: profileID)
            await activityProvider.reset(connectionID: profileID)
            statusByConnectionID.removeValue(forKey: profileID)
            onActivitySourceChanged?()
        } catch {
            statusByConnectionID[profileID] = .unavailable
        }
    }

    private func startRecovery(profileID: UUID) {
        recoveryTask?.cancel()
        guard let profile = profiles.first(where: { $0.id == profileID }) else {
            recoveringConnectionID = nil
            recoveryPhase = .requestingCode
            recoveryTask = nil
            return
        }

        let clientID = profile.clientID?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !clientID.isEmpty else {
            recoveryTask = nil
            recoveryPhase = .failed(
                message: "This saved GitHub connection is missing the client ID required for re-authentication. Add the connection again to repair it."
            )
            return
        }

        let generation = advanceOperationGeneration(for: profile.id)
        recoveryPhase = .requestingCode

        recoveryTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let authorization = try await deviceFlowClient.begin(
                    connection: profile.connection,
                    clientID: clientID
                )
                try Task.checkCancellation()
                guard isCurrentOperationGeneration(generation, for: profile.id) else { return }

                recoveryPhase = .waitingForAuthorization(
                    GitHubDeviceAuthorizationPresentation(
                        userCode: authorization.userCode,
                        verificationURI: authorization.verificationURI,
                        expiresAt: authorization.expiresAt
                    )
                )

                let credential = try await authorizationWaiter.waitForAuthorization(
                    connection: profile.connection,
                    clientID: clientID,
                    session: authorization
                )
                try Task.checkCancellation()
                guard isCurrentOperationGeneration(generation, for: profile.id) else { return }

                recoveryPhase = .finalizing
                let session = try await sessionCoordinator.recover(
                    connection: profile.connection,
                    expectedIdentity: profile.account,
                    credential: credential
                )
                try Task.checkCancellation()

                guard isCurrentOperationGeneration(generation, for: profile.id),
                      let current = profiles.first(where: { $0.id == profile.id }),
                      current.account.id == profile.account.id,
                      current.connection.id == profile.connection.id
                else {
                    return
                }

                let updated = GitHubConnectionProfile(
                    connection: current.connection,
                    account: session.account.identity,
                    authenticationMethod: current.authenticationMethod,
                    clientID: current.clientID,
                    repositorySelection: current.repositorySelection,
                    isEnabled: current.isEnabled,
                    createdAt: current.createdAt,
                    lastConnectedAt: .now,
                    lastEnterpriseMetadataCheckAt: current.lastEnterpriseMetadataCheckAt
                )

                do {
                    try await profileStore.save(updated)
                } catch {
                    guard isCurrentOperationGeneration(generation, for: profile.id) else { return }
                    statusByConnectionID[profile.id] = .unavailable
                    recoveryTask = nil
                    recoveryPhase = .failed(message: recoveryErrorMessage(for: error, profile: profile))
                    return
                }

                guard isCurrentOperationGeneration(generation, for: profile.id),
                      let currentAfterSave = profiles.first(where: { $0.id == profile.id }),
                      currentAfterSave.account.id == profile.account.id
                else {
                    await repairProfileStoreAfterStaleWrite(profileID: profile.id)
                    return
                }

                await activityProvider.reset(connectionID: updated.id)
                guard isCurrentOperationGeneration(generation, for: profile.id) else {
                    await repairProfileStoreAfterStaleWrite(profileID: profile.id)
                    return
                }

                upsert(updated)
                inventoryByConnectionID[updated.id] = session.inventory
                capabilitiesByConnectionID[updated.id] = session.capabilities
                statusByConnectionID[updated.id] = updated.isEnabled
                    ? presentationStatus(
                        for: session.inventory,
                        connection: updated.connection
                    )
                    : .disabled
                onActivitySourceChanged?()
                recoveryTask = nil
                recoveringConnectionID = nil
                recoveryPhase = .requestingCode
            } catch is CancellationError {
                if isCurrentOperationGeneration(generation, for: profile.id) {
                    recoveryTask = nil
                }
            } catch {
                guard isCurrentOperationGeneration(generation, for: profile.id) else { return }
                applyRecoveryFailureStatus(error, profileID: profile.id)
                recoveryTask = nil
                recoveryPhase = .failed(
                    message: recoveryErrorMessage(for: error, profile: profile)
                )
            }
        }
    }

    private func advanceOperationGeneration(for connectionID: UUID) -> UInt64 {
        let next = (operationGenerationByConnectionID[connectionID] ?? 0) &+ 1
        operationGenerationByConnectionID[connectionID] = next
        return next
    }

    private func isCurrentOperationGeneration(
        _ generation: UInt64,
        for connectionID: UUID
    ) -> Bool {
        operationGenerationByConnectionID[connectionID] == generation
    }

    private func repairProfileStoreAfterStaleWrite(profileID: UUID) async {
        if let current = profiles.first(where: { $0.id == profileID }) {
            try? await profileStore.save(current)
        } else {
            try? await profileStore.delete(id: profileID)
        }
    }

    private func applyRecoveryFailureStatus(_ error: Error, profileID: UUID) {
        guard let sessionError = error as? GitHubConnectionSessionError else { return }

        switch sessionError {
        case .credentialNotFound, .reauthenticationRequired, .accountMismatch:
            statusByConnectionID[profileID] = .authenticationRequired
        case .connectionEndpointMismatch:
            statusByConnectionID[profileID] = .unavailable
        }
    }

    private func recoveryErrorMessage(
        for error: Error,
        profile: GitHubConnectionProfile
    ) -> String {
        if case GitHubConnectionSessionError.accountMismatch = error {
            return "GitHub authorized a different account. Sign in as @\(profile.account.login) and try again."
        }
        if case GitHubConnectionSessionError.reauthenticationRequired = error {
            return "GitHub rejected the new credential. Request a new authorization code and try again."
        }
        return errorMessage(for: error)
    }

    private func accessibleRepositories(
        _ inventory: GitHubAccessInventory
    ) -> [GitHubRepositoryAccess] {
        var seen = Set<Int64>()
        return inventory.installations
            .filter { $0.status == .available }
            .flatMap(\.repositories)
            .filter { seen.insert($0.id).inserted }
            .sorted { lhs, rhs in
                if lhs.fullName != rhs.fullName {
                    return lhs.fullName < rhs.fullName
                }
                return lhs.id < rhs.id
            }
    }

    func repositoryAccess(
        profileID: UUID,
        fullName: String
    ) -> GitHubRepositoryAccess? {
        guard let inventory = inventoryByConnectionID[profileID] else {
            return nil
        }

        var match: GitHubRepositoryAccess?
        for repository in accessibleRepositories(inventory)
        where repository.fullName == fullName {
            guard match == nil else {
                return nil
            }
            match = repository
        }
        return match
    }

    func actionsAccessPresentation(
        profileID: UUID,
        repositoryID: Int64
    ) -> GitHubRepositoryActivityAccessPresentation {
        activityAccessPresentation(
            capabilitiesByConnectionID[profileID]?.state(
                for: .actions,
                repositoryID: repositoryID
            )
        )
    }

    func deploymentAccessPresentation(
        profileID: UUID,
        repositoryID: Int64
    ) -> GitHubRepositoryActivityAccessPresentation {
        activityAccessPresentation(
            capabilitiesByConnectionID[profileID]?.state(
                for: .deployments,
                repositoryID: repositoryID
            )
        )
    }

    private func activityAccessPresentation(
        _ state: GitHubCapabilityState?
    ) -> GitHubRepositoryActivityAccessPresentation {
        switch state {
        case .available:
            return .available
        case .unavailable:
            return .unavailable
        case .unknown, nil:
            return .unverified
        }
    }

    private func applyActivityStatus(
        _ result: GitHubActivityLoadResult,
        profileID: UUID,
        inventory: GitHubAccessInventory,
        connection: GitHubConnection
    ) {
        if result.attemptedTargetCount == 0 {
            statusByConnectionID[profileID] = presentationStatus(
                for: inventory,
                connection: connection
            )
            return
        }

        if result.successfulTargetCount > 0 {
            statusByConnectionID[profileID] = presentationStatus(
                for: inventory,
                connection: connection
            )
            return
        }

        let operationalFailures = result.targetFailures.filter {
            $0.reason != .capabilityUnavailable
        }
        guard !operationalFailures.isEmpty else {
            statusByConnectionID[profileID] = presentationStatus(
                for: inventory,
                connection: connection
            )
            return
        }

        if operationalFailures.allSatisfy({ $0.reason == .networkUnavailable }) {
            statusByConnectionID[profileID] = .networkUnavailable
        } else {
            statusByConnectionID[profileID] = .unavailable
        }
    }

    private func refreshEnterpriseMetadataIfDue(
        _ profile: GitHubConnectionProfile,
        at checkTime: Date
    ) async throws -> GitHubConnectionProfile {
        guard enterpriseMetadataRefreshPolicy.shouldRefresh(
            connection: profile.connection,
            lastCheckedAt: profile.lastEnterpriseMetadataCheckAt,
            now: checkTime
        ) else {
            return profile
        }

        var updated = profile
        updated.lastEnterpriseMetadataCheckAt = checkTime

        do {
            let discovery = try await enterpriseDiscovery.discover(
                connection: profile.connection
            )
            try Task.checkCancellation()
            updated.connection.applyDiscoveredServerVersion(
                discovery.installedVersion
            )
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            try Task.checkCancellation()
        }

        return updated
    }

    private func makeConnection(from draft: GitHubConnectionDraft) async throws -> GitHubConnection {
        let displayName = draft.displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        let rawURL: String
        switch draft.deploymentKind {
        case .githubDotCom:
            rawURL = "https://github.com"
        case .gheDotCom, .enterpriseServer:
            rawURL = draft.serverURL.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        guard let webBaseURL = URL(string: rawURL) else {
            throw RuntimeError.invalidServerURL
        }

        _ = try GitHubEndpointResolver.resolve(
            deploymentKind: draft.deploymentKind,
            webBaseURL: webBaseURL
        )

        var connection = GitHubConnection(
            displayName: displayName,
            deploymentKind: draft.deploymentKind,
            webBaseURL: webBaseURL
        )

        if draft.deploymentKind == .enterpriseServer {
            let discovery = try await enterpriseDiscovery.discover(
                connection: connection
            )
            connection.applyDiscoveredServerVersion(
                discovery.installedVersion
            )
        }

        return connection
    }

    private func presentationStatus(
        for inventory: GitHubAccessInventory,
        connection: GitHubConnection
    ) -> GitHubConnectionPresentationStatus {
        let available = inventory.installations.filter { $0.status == .available }
        let repositoryIDs = Set(available.flatMap { $0.repositories.map(\.id) })

        let operationalStatus: GitHubConnectionPresentationStatus
        if !available.isEmpty || inventory.installations.isEmpty {
            operationalStatus = .connected(repositoryCount: repositoryIDs.count)
        } else if inventory.installations.allSatisfy({ $0.status == .suspended }) {
            operationalStatus = .suspended
        } else {
            operationalStatus = .unavailable
        }

        guard case .connected = operationalStatus,
              connection.deploymentKind == .enterpriseServer,
              let rawVersion = connection.serverVersion?
                .trimmingCharacters(in: .whitespacesAndNewlines),
              !rawVersion.isEmpty
        else {
            return operationalStatus
        }

        let parsedVersion = GitHubEnterpriseServerVersion(parsing: rawVersion)
        switch enterpriseCompatibilityPolicy.compatibility(for: parsedVersion) {
        case .tested:
            return operationalStatus
        case .olderUntested, .newerUntested, .unknownVersion:
            return .untestedServer(version: rawVersion)
        }
    }

    private func displayHost(for connection: GitHubConnection) -> String {
        guard let components = URLComponents(
            url: connection.webBaseURL,
            resolvingAgainstBaseURL: false
        ), let host = components.host
        else {
            return connection.webBaseURL.absoluteString
        }

        if let port = components.port {
            return "\(host):\(port)"
        }
        return host
    }

    private func deploymentLabel(for connection: GitHubConnection) -> String {
        switch connection.deploymentKind {
        case .githubDotCom:
            return "GitHub.com"
        case .gheDotCom:
            return "GHE.com"
        case .enterpriseServer:
            if let version = connection.serverVersion {
                return "GHES \(version)"
            }
            return "GitHub Enterprise Server"
        }
    }

    private func repositorySelectionLabel(for profile: GitHubConnectionProfile) -> String {
        switch profile.repositorySelection {
        case .allAccessible:
            return "All accessible repositories"
        case let .selected(ids):
            return "\(ids.count) selected repositories"
        }
    }

    private func upsert(_ profile: GitHubConnectionProfile) {
        if let index = profiles.firstIndex(where: { $0.id == profile.id }) {
            profiles[index] = profile
        } else {
            profiles.append(profile)
        }
        profiles = GitHubConnectionProfileOrdering.sorted(profiles)
    }

    private func errorMessage(for error: Error) -> String {
        switch error {
        case GitHubDeviceFlowError.deviceFlowDisabled:
            return "Device Flow is disabled for this GitHub App. Enable Device Flow in the GitHub App settings."
        case GitHubDeviceFlowError.incorrectClientCredentials,
             GitHubDeviceFlowError.invalidClientID:
            return "The GitHub App client ID is invalid."
        case GitHubDeviceAuthorizationWaitError.accessDenied:
            return "GitHub authorization was denied."
        case GitHubDeviceAuthorizationWaitError.expired:
            return "The GitHub authorization code expired. Request a new code."
        case GitHubEndpointResolverError.httpsRequired,
             GitHubEndpointResolverError.missingHost,
             GitHubEndpointResolverError.credentialsNotAllowed,
             GitHubEndpointResolverError.queryOrFragmentNotAllowed,
             GitHubEndpointResolverError.pathNotAllowed,
             GitHubEndpointResolverError.nonStandardPortNotAllowed,
             GitHubEndpointResolverError.invalidGitHubDotComHost,
             GitHubEndpointResolverError.invalidGHEHost,
             RuntimeError.invalidServerURL:
            return "The GitHub server URL is invalid or unsupported."
        case let GitHubEnterpriseServerDiscoveryError.httpStatus(status):
            return "GitHub Enterprise Server discovery failed with HTTP \(status)."
        default:
            return "Could not connect to GitHub. Check the server, network, and GitHub App configuration."
        }
    }

    private enum RuntimeError: Error {
        case invalidServerURL
        case activityAuthenticationRequired
        case activityUnavailable
    }
}

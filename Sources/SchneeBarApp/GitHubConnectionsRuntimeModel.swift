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

    @ObservationIgnored
    private let profileStore: any GitHubConnectionProfileStore

    @ObservationIgnored
    private let sessionCoordinator: GitHubConnectionSessionCoordinator

    @ObservationIgnored
    private let activityProvider: GitHubActivityProvider

    @ObservationIgnored
    private let deviceFlowClient: GitHubDeviceFlowClient

    @ObservationIgnored
    private let authorizationWaiter: GitHubDeviceAuthorizationWaiter

    @ObservationIgnored
    private let enterpriseDiscovery: GitHubEnterpriseServerDiscoveryClient

    @ObservationIgnored
    private var inventoryByConnectionID: [UUID: GitHubAccessInventory] = [:]

    @ObservationIgnored
    private var onboardingTask: Task<Void, Never>?

    init(
        profileStore: any GitHubConnectionProfileStore,
        sessionCoordinator: GitHubConnectionSessionCoordinator,
        activityProvider: GitHubActivityProvider,
        deviceFlowClient: GitHubDeviceFlowClient = GitHubDeviceFlowClient(),
        authorizationWaiter: GitHubDeviceAuthorizationWaiter = GitHubDeviceAuthorizationWaiter(),
        enterpriseDiscovery: GitHubEnterpriseServerDiscoveryClient = GitHubEnterpriseServerDiscoveryClient()
    ) {
        self.profileStore = profileStore
        self.sessionCoordinator = sessionCoordinator
        self.activityProvider = activityProvider
        self.deviceFlowClient = deviceFlowClient
        self.authorizationWaiter = authorizationWaiter
        self.enterpriseDiscovery = enterpriseDiscovery
    }

    var onboardingIsActive: Bool {
        switch onboardingPhase {
        case .requestingCode, .waitingForAuthorization, .finalizing:
            return true
        case .configuration, .failed:
            return false
        }
    }

    var connectionCards: [GitHubConnectionCardModel] {
        profiles.map { profile in
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

    func load() async {
        do {
            profiles = try await profileStore.loadAll()
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
        var allFailures: [GitHubRepositoryActivityFailure] = []
        var attemptedRepositoryCount = 0
        var successfulRepositoryCount = 0

        for profile in profiles where profile.isEnabled {
            guard let inventory = inventoryByConnectionID[profile.id] else {
                continue
            }

            let result = await activityProvider.load(
                profile: profile,
                inventory: inventory
            )
            items.append(contentsOf: result.items)
            allFailures.append(contentsOf: result.failures)
            attemptedRepositoryCount += result.attemptedRepositoryCount
            successfulRepositoryCount += result.successfulRepositoryCount
            applyActivityStatus(result, profileID: profile.id)
        }

        if attemptedRepositoryCount > 0,
           successfulRepositoryCount == 0,
           !allFailures.isEmpty
        {
            if allFailures.contains(where: { $0.reason == .authenticationRequired }) {
                throw RuntimeError.activityAuthenticationRequired
            }

            let isTransientOutage = allFailures.allSatisfy {
                $0.reason == .networkUnavailable || $0.reason == .unavailable
            }
            if isTransientOutage {
                throw RuntimeError.activityUnavailable
            }
        }

        return items.sorted(by: activityItemSort)
    }

    func beginOnboarding(defaultClientID: String? = nil) {
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
                let profile = GitHubConnectionProfile(
                    connection: connection,
                    account: session.account.identity,
                    authenticationMethod: .deviceFlow,
                    clientID: clientID,
                    repositorySelection: .allAccessible,
                    isEnabled: true,
                    createdAt: now,
                    lastConnectedAt: now
                )

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

                upsert(profile)
                inventoryByConnectionID[profile.id] = session.inventory
                statusByConnectionID[profile.id] = presentationStatus(for: session.inventory)
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

    func refresh(profileID: UUID) async {
        guard let profile = profiles.first(where: { $0.id == profileID }) else { return }
        guard profile.isEnabled else {
            inventoryByConnectionID.removeValue(forKey: profileID)
            statusByConnectionID[profileID] = .disabled
            return
        }

        statusByConnectionID[profileID] = .syncing
        do {
            let session = try await sessionCoordinator.restore(
                connection: profile.connection,
                identity: profile.account,
                clientID: profile.clientID
            )
            inventoryByConnectionID[profileID] = session.inventory
            statusByConnectionID[profileID] = presentationStatus(for: session.inventory)

            var updated = profile
            updated.lastConnectedAt = .now
            try await profileStore.save(updated)
            upsert(updated)
        } catch GitHubConnectionSessionError.credentialNotFound,
                GitHubConnectionSessionError.reauthenticationRequired,
                GitHubConnectionSessionError.accountMismatch(_, _) {
            inventoryByConnectionID.removeValue(forKey: profileID)
            statusByConnectionID[profileID] = .authenticationRequired
        } catch let error as URLError where error.code == .notConnectedToInternet
            || error.code == .cannotFindHost
            || error.code == .cannotConnectToHost
            || error.code == .dnsLookupFailed
            || error.code == .timedOut
        {
            statusByConnectionID[profileID] = .networkUnavailable
        } catch {
            statusByConnectionID[profileID] = .unavailable
        }
    }

    func setEnabled(_ isEnabled: Bool, profileID: UUID) {
        guard var profile = profiles.first(where: { $0.id == profileID }) else { return }
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
            inventoryByConnectionID.removeValue(forKey: profileID)
            statusByConnectionID[profileID] = .disabled
        }
    }

    func disconnect(profileID: UUID) async {
        guard let profile = profiles.first(where: { $0.id == profileID }) else { return }
        do {
            try await sessionCoordinator.disconnect(
                connection: profile.connection,
                identity: profile.account
            )
            try await profileStore.delete(id: profileID)
            profiles.removeAll(where: { $0.id == profileID })
            inventoryByConnectionID.removeValue(forKey: profileID)
            statusByConnectionID.removeValue(forKey: profileID)
        } catch {
            statusByConnectionID[profileID] = .unavailable
        }
    }

    private func applyActivityStatus(
        _ result: GitHubActivityLoadResult,
        profileID: UUID
    ) {
        guard result.attemptedRepositoryCount > 0 else { return }

        if result.failures.contains(where: { $0.reason == .authenticationRequired }) {
            statusByConnectionID[profileID] = .authenticationRequired
            return
        }

        guard result.successfulRepositoryCount == 0,
              !result.failures.isEmpty
        else {
            return
        }

        if result.failures.allSatisfy({ $0.reason == .networkUnavailable }) {
            statusByConnectionID[profileID] = .networkUnavailable
        } else if result.failures.allSatisfy({
            $0.reason == .networkUnavailable || $0.reason == .unavailable
        }) {
            statusByConnectionID[profileID] = .unavailable
        }
    }

    private func activityItemSort(lhs: ActivityItem, rhs: ActivityItem) -> Bool {
        let lhsPriority = activityPriority(lhs.state)
        let rhsPriority = activityPriority(rhs.state)
        if lhsPriority != rhsPriority {
            return lhsPriority < rhsPriority
        }
        if lhs.repository != rhs.repository {
            return lhs.repository < rhs.repository
        }
        if lhs.context != rhs.context {
            return lhs.context < rhs.context
        }
        return lhs.id < rhs.id
    }

    private func activityPriority(_ state: ActivityState) -> Int {
        switch state {
        case .failed: 0
        case .running: 1
        case .waiting: 2
        case .success: 3
        }
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
            let discovery = try await enterpriseDiscovery.discover(connection: connection)
            connection.serverVersion = discovery.installedVersion
        }

        return connection
    }

    private func presentationStatus(
        for inventory: GitHubAccessInventory
    ) -> GitHubConnectionPresentationStatus {
        let available = inventory.installations.filter { $0.status == .available }
        let repositoryIDs = Set(available.flatMap { $0.repositories.map(\.id) })

        if !available.isEmpty || inventory.installations.isEmpty {
            return .connected(repositoryCount: repositoryIDs.count)
        }
        if inventory.installations.allSatisfy({ $0.status == .suspended }) {
            return .suspended
        }
        return .unavailable
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

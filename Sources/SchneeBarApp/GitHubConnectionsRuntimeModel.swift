import Foundation
import Observation
import SchneeBarGitHub
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
    private let deviceFlowClient: GitHubDeviceFlowClient

    @ObservationIgnored
    private let authorizationWaiter: GitHubDeviceAuthorizationWaiter

    @ObservationIgnored
    private let enterpriseDiscovery: GitHubEnterpriseServerDiscoveryClient

    @ObservationIgnored
    private var onboardingTask: Task<Void, Never>?

    init(
        profileStore: any GitHubConnectionProfileStore,
        sessionCoordinator: GitHubConnectionSessionCoordinator,
        deviceFlowClient: GitHubDeviceFlowClient = GitHubDeviceFlowClient(),
        authorizationWaiter: GitHubDeviceAuthorizationWaiter = GitHubDeviceAuthorizationWaiter(),
        enterpriseDiscovery: GitHubEnterpriseServerDiscoveryClient = GitHubEnterpriseServerDiscoveryClient()
    ) {
        self.profileStore = profileStore
        self.sessionCoordinator = sessionCoordinator
        self.deviceFlowClient = deviceFlowClient
        self.authorizationWaiter = authorizationWaiter
        self.enterpriseDiscovery = enterpriseDiscovery
    }

    deinit {
        onboardingTask?.cancel()
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
                    ?? (profile.isEnabled ? .syncing : .unavailable),
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

        for profile in profiles where profile.isEnabled {
            statusByConnectionID[profile.id] = .syncing
            Task { @MainActor [weak self] in
                await self?.refresh(profileID: profile.id)
            }
        }
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
                try Task.checkCancellation()

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
                try await profileStore.save(profile)

                upsert(profile)
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
            statusByConnectionID[profileID] = .unavailable
            return
        }

        statusByConnectionID[profileID] = .syncing
        do {
            let session = try await sessionCoordinator.restore(
                connection: profile.connection,
                identity: profile.account,
                clientID: profile.clientID
            )
            statusByConnectionID[profileID] = presentationStatus(for: session.inventory)

            var updated = profile
            updated.lastConnectedAt = .now
            try await profileStore.save(updated)
            upsert(updated)
        } catch GitHubConnectionSessionError.credentialNotFound,
                GitHubConnectionSessionError.reauthenticationRequired,
                GitHubConnectionSessionError.accountMismatch {
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
            statusByConnectionID[profileID] = .unavailable
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
            statusByConnectionID.removeValue(forKey: profileID)
        } catch {
            statusByConnectionID[profileID] = .unavailable
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
        case GitHubEndpointError.invalidURL,
             GitHubEndpointError.httpsRequired,
             GitHubEndpointError.unexpectedHost:
            return "The GitHub server URL is invalid or unsupported."
        case let GitHubEnterpriseServerDiscoveryError.httpStatus(status):
            return "GitHub Enterprise Server discovery failed with HTTP \(status)."
        default:
            return "Could not connect to GitHub. Check the server, network, and GitHub App configuration."
        }
    }

    private enum RuntimeError: Error {
        case invalidServerURL
    }
}

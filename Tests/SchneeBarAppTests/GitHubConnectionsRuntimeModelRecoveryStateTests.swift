@testable import SchneeBar
import Foundation
import SchneeBarGitHub
import SchneeBarGitHubActivityProvider
import Testing

private actor RecoveryStateProfileStore: GitHubConnectionProfileStore {
    private var values: [UUID: GitHubConnectionProfile]

    init(_ profiles: [GitHubConnectionProfile]) {
        values = Dictionary(uniqueKeysWithValues: profiles.map { ($0.id, $0) })
    }

    func loadAll() async throws -> [GitHubConnectionProfile] {
        Array(values.values)
    }

    func load(id: UUID) async throws -> GitHubConnectionProfile? {
        values[id]
    }

    func save(_ profile: GitHubConnectionProfile) async throws {
        values[profile.id] = profile
    }

    func delete(id: UUID) async throws {
        values.removeValue(forKey: id)
    }
}

private actor RecoveryStateCredentialStore: GitHubCredentialStore {
    func load(for key: GitHubCredentialKey) async throws -> GitHubCredential? { nil }
    func save(_ credential: GitHubCredential, for key: GitHubCredentialKey) async throws {}
    func delete(for key: GitHubCredentialKey) async throws {}
}

private struct RecoveryStateWorkflowLoader: GitHubWorkflowRunLoading {
    func workflowRuns(
        connection: GitHubConnection,
        identity: GitHubAccountIdentity,
        clientID: String?,
        repository: GitHubRepositoryAccess,
        query: GitHubWorkflowRunQuery
    ) async throws -> [GitHubWorkflowRun] {
        []
    }
}

@Test @MainActor
func beginOnboardingCancelsExistingRecoveryState() async throws {
    let original = try recoveryStateProfile(clientID: nil)
    let fixture = recoveryStateFixture(original)
    fixture.model.profiles = [original]
    fixture.model.statusByConnectionID[original.id] = .authenticationRequired

    fixture.model.beginRecovery(profileID: original.id)
    #expect(fixture.model.recoveringConnectionID == original.id)
    #expect(fixture.model.recoveryContext?.accountLogin == original.account.login)
    #expect(fixture.model.recoveryIsActive == false)

    fixture.model.beginOnboarding(defaultClientID: "test-client-id")

    #expect(fixture.model.recoveringConnectionID == nil)
    #expect(fixture.model.recoveryPhase == .requestingCode)
    #expect(fixture.model.isPresentingOnboarding)
    #expect(fixture.model.onboardingPhase == .configuration)
    #expect(fixture.model.profiles == [original])
    #expect(fixture.model.statusByConnectionID[original.id] == .authenticationRequired)
}

@Test @MainActor
func enterprisePreflightCountsAsActiveOnboarding() async throws {
    let original = try recoveryStateProfile(clientID: nil)
    let fixture = recoveryStateFixture(original)

    fixture.model.onboardingPhase = .checkingEnterpriseServer

    #expect(fixture.model.onboardingIsActive)
}

@Test @MainActor
func beginRecoveryCancelsExistingOnboardingState() async throws {
    let original = try recoveryStateProfile(clientID: nil)
    let fixture = recoveryStateFixture(original)
    fixture.model.profiles = [original]
    fixture.model.statusByConnectionID[original.id] = .authenticationRequired
    fixture.model.beginOnboarding(defaultClientID: "another-client")

    fixture.model.beginRecovery(profileID: original.id)

    #expect(fixture.model.isPresentingOnboarding == false)
    #expect(fixture.model.onboardingPhase == .configuration)
    #expect(fixture.model.recoveringConnectionID == original.id)
    #expect(
        fixture.model.recoveryPhase
            == .failed(
                message: "This saved GitHub connection is missing the client ID required for re-authentication. Add the connection again to repair it."
            )
    )
}

@Test @MainActor
func cancelRecoveryLeavesProfileAndConnectionStatusUntouched() async throws {
    let original = try recoveryStateProfile(clientID: nil)
    let fixture = recoveryStateFixture(original)
    fixture.model.profiles = [original]
    fixture.model.statusByConnectionID[original.id] = .authenticationRequired

    fixture.model.beginRecovery(profileID: original.id)
    fixture.model.cancelRecovery()

    #expect(fixture.model.recoveringConnectionID == nil)
    #expect(fixture.model.recoveryPhase == .requestingCode)
    #expect(fixture.model.profiles == [original])
    #expect(fixture.model.statusByConnectionID[original.id] == .authenticationRequired)
    #expect(try await fixture.store.load(id: original.id) == original)
}

@MainActor
private struct RecoveryStateFixture {
    let model: GitHubConnectionsRuntimeModel
    let store: RecoveryStateProfileStore
}

@MainActor
private func recoveryStateFixture(_ profile: GitHubConnectionProfile) -> RecoveryStateFixture {
    let store = RecoveryStateProfileStore([profile])
    let coordinator = GitHubConnectionSessionCoordinator(
        credentialStore: RecoveryStateCredentialStore()
    )
    let activityProvider = GitHubActivityProvider(
        workflowRunLoader: RecoveryStateWorkflowLoader()
    )
    return RecoveryStateFixture(
        model: GitHubConnectionsRuntimeModel(
            profileStore: store,
            sessionCoordinator: coordinator,
            activityProvider: activityProvider
        ),
        store: store
    )
}

private func recoveryStateProfile(clientID: String?) throws -> GitHubConnectionProfile {
    GitHubConnectionProfile(
        connection: GitHubConnection(
            id: UUID(uuidString: "31000000-0000-0000-0000-000000000001")!,
            displayName: "GitHub.com",
            deploymentKind: .githubDotCom,
            webBaseURL: try #require(URL(string: "https://github.com"))
        ),
        account: GitHubAccountIdentity(id: "42", login: "snow-user"),
        authenticationMethod: .deviceFlow,
        clientID: clientID,
        repositorySelection: .selected([1, 2, 3]),
        isEnabled: true,
        createdAt: Date(timeIntervalSince1970: 1_000),
        lastConnectedAt: Date(timeIntervalSince1970: 2_000)
    )
}

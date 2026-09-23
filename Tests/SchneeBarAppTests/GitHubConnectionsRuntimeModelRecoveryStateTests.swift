@testable import SchneeBar
import Foundation
import SchneeBarGitHub
import SchneeBarGitHubActivityProvider
import SchneeBarGitHubFeature
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

private actor RecoveryStateDiscoveryTransport: GitHubHTTPTransport {
    private let installedVersion: String
    private var requests: [URLRequest] = []

    init(installedVersion: String) {
        self.installedVersion = installedVersion
    }

    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        requests.append(request)
        let response = try #require(
            HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: "HTTP/1.1",
                headerFields: nil
            )
        )
        let json = "{\"installed_version\":\"\(installedVersion)\"}"
        return (Data(json.utf8), response)
    }

    func requestCount() -> Int {
        requests.count
    }
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
func enterpriseReviewCountsAsActiveOnboarding() async throws {
    let original = try recoveryStateProfile(clientID: nil)
    let fixture = recoveryStateFixture(original)

    fixture.model.onboardingPhase = .reviewingEnterpriseServer(
        GitHubEnterpriseServerPreflightPresentation(
            host: "github.internal.example",
            installedVersion: "3.22.0",
            compatibility: .tested
        )
    )

    #expect(fixture.model.onboardingIsActive)
}

@Test @MainActor
func enterpriseOnboardingPausesAfterDiscoveryForReview() async throws {
    let original = try recoveryStateProfile(clientID: nil)
    let transport = RecoveryStateDiscoveryTransport(installedVersion: "3.23.0")
    let fixture = recoveryStateFixture(
        original,
        enterpriseDiscovery: GitHubEnterpriseServerDiscoveryClient(
            transport: transport
        )
    )

    fixture.model.beginOnboarding(defaultClientID: "Iv1.enterprise-client")
    fixture.model.onboardingDraft = GitHubConnectionDraft(
        deploymentKind: .enterpriseServer,
        displayName: "Internal GitHub",
        serverURL: "https://github.internal.example:8443",
        clientID: "Iv1.enterprise-client"
    )
    fixture.model.connectDraft()

    let presentation = try #require(
        await waitForEnterpriseReview(fixture.model)
    )

    #expect(presentation.host == "github.internal.example:8443")
    #expect(presentation.installedVersion == "3.23.0")
    #expect(presentation.compatibility == .newerUntested)
    #expect(fixture.model.onboardingIsActive)
    #expect(await transport.requestCount() == 1)
}

@Test @MainActor
func cancellingEnterpriseReviewPreventsContinuation() async throws {
    let original = try recoveryStateProfile(clientID: nil)
    let transport = RecoveryStateDiscoveryTransport(installedVersion: "3.22.0")
    let fixture = recoveryStateFixture(
        original,
        enterpriseDiscovery: GitHubEnterpriseServerDiscoveryClient(
            transport: transport
        )
    )

    fixture.model.beginOnboarding(defaultClientID: "Iv1.enterprise-client")
    fixture.model.onboardingDraft = GitHubConnectionDraft(
        deploymentKind: .enterpriseServer,
        displayName: "Internal GitHub",
        serverURL: "https://github.internal.example",
        clientID: "Iv1.enterprise-client"
    )
    fixture.model.connectDraft()
    _ = try #require(await waitForEnterpriseReview(fixture.model))

    fixture.model.cancelOnboarding()
    fixture.model.continueEnterpriseOnboarding()

    #expect(fixture.model.onboardingPhase == .configuration)
    #expect(!fixture.model.isPresentingOnboarding)
    #expect(await transport.requestCount() == 1)
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
private func recoveryStateFixture(
    _ profile: GitHubConnectionProfile,
    enterpriseDiscovery: GitHubEnterpriseServerDiscoveryClient = .init()
) -> RecoveryStateFixture {
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
            activityProvider: activityProvider,
            enterpriseDiscovery: enterpriseDiscovery
        ),
        store: store
    )
}

@MainActor
private func waitForEnterpriseReview(
    _ model: GitHubConnectionsRuntimeModel
) async -> GitHubEnterpriseServerPreflightPresentation? {
    for _ in 0 ..< 100 {
        if case let .reviewingEnterpriseServer(presentation) = model.onboardingPhase {
            return presentation
        }
        await Task.yield()
    }
    return nil
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

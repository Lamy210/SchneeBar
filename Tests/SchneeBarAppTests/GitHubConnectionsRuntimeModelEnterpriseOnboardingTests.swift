@testable import SchneeBar
import Foundation
import SchneeBarGitHub
import SchneeBarGitHubActivityProvider
import SchneeBarGitHubFeature
import Testing

private actor EnterpriseOnboardingProfileStore: GitHubConnectionProfileStore {
    func loadAll() async throws -> [GitHubConnectionProfile] { [] }
    func load(id: UUID) async throws -> GitHubConnectionProfile? { nil }
    func save(_ profile: GitHubConnectionProfile) async throws {}
    func delete(id: UUID) async throws {}
}

private actor EnterpriseOnboardingCredentialStore: GitHubCredentialStore {
    func load(for key: GitHubCredentialKey) async throws -> GitHubCredential? { nil }
    func save(_ credential: GitHubCredential, for key: GitHubCredentialKey) async throws {}
    func delete(for key: GitHubCredentialKey) async throws {}
}

private struct EnterpriseOnboardingWorkflowLoader: GitHubWorkflowRunLoading {
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

private actor EnterpriseOnboardingTransport: GitHubHTTPTransport {
    private let installedVersion: String
    private var metaRequests = 0
    private var deviceCodeRequests = 0
    private var tokenRequests = 0

    init(installedVersion: String = "3.23.0") {
        self.installedVersion = installedVersion
    }

    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let path = request.url?.path ?? ""
        let json: String
        let statusCode: Int

        if path.hasSuffix("/api/v3/meta") {
            metaRequests += 1
            json = "{\"installed_version\":\"\(installedVersion)\"}"
            statusCode = 200
        } else if path.hasSuffix("/login/device/code") {
            deviceCodeRequests += 1
            json = #"{"device_code":"test-device","user_code":"ABCD-EFGH","verification_uri":"https://github.internal.example/login/device","expires_in":900,"interval":1}"#
            statusCode = 200
        } else if path.hasSuffix("/login/oauth/access_token") {
            tokenRequests += 1
            json = #"{"error":"authorization_pending"}"#
            statusCode = 200
        } else {
            json = #"{"message":"Unexpected request"}"#
            statusCode = 500
        }

        let response = try #require(
            HTTPURLResponse(
                url: request.url!,
                statusCode: statusCode,
                httpVersion: "HTTP/1.1",
                headerFields: nil
            )
        )
        return (Data(json.utf8), response)
    }

    func counts() -> (meta: Int, deviceCode: Int, token: Int) {
        (metaRequests, deviceCodeRequests, tokenRequests)
    }
}

@Test @MainActor
func untestedEnterpriseServerRequiresConfirmationBeforeDeviceFlow() async throws {
    let transport = EnterpriseOnboardingTransport()
    let deviceFlowClient = GitHubDeviceFlowClient(
        transport: transport,
        now: { Date(timeIntervalSince1970: 100_000) }
    )
    let waiter = GitHubDeviceAuthorizationWaiter(
        client: deviceFlowClient,
        sleeper: { _ in
            try await Task.sleep(nanoseconds: 60_000_000_000)
        }
    )
    let credentialStore = EnterpriseOnboardingCredentialStore()
    let model = GitHubConnectionsRuntimeModel(
        profileStore: EnterpriseOnboardingProfileStore(),
        sessionCoordinator: GitHubConnectionSessionCoordinator(
            credentialStore: credentialStore
        ),
        activityProvider: GitHubActivityProvider(
            workflowRunLoader: EnterpriseOnboardingWorkflowLoader()
        ),
        deviceFlowClient: deviceFlowClient,
        authorizationWaiter: waiter,
        enterpriseDiscovery: GitHubEnterpriseServerDiscoveryClient(
            transport: transport
        )
    )

    model.beginOnboarding(defaultClientID: "Iv1.enterprise-client")
    model.onboardingDraft = GitHubConnectionDraft(
        deploymentKind: .enterpriseServer,
        displayName: "Internal GitHub",
        serverURL: "https://github.internal.example",
        clientID: "Iv1.enterprise-client"
    )
    model.connectDraft()

    try await waitForEnterpriseCompatibilityWarning(model)

    guard case let .enterpriseServerCompatibilityWarning(presentation)
        = model.onboardingPhase
    else {
        Issue.record("Expected GHES compatibility warning")
        return
    }

    #expect(presentation.installedVersion == "3.23.0")
    #expect(presentation.compatibility == .newerUntested)
    #expect(model.onboardingIsActive)

    var counts = await transport.counts()
    #expect(counts.meta == 1)
    #expect(counts.deviceCode == 0)

    model.continueEnterpriseServerOnboarding()
    try await waitForDeviceAuthorizationPresentation(model)

    counts = await transport.counts()
    #expect(counts.meta == 1)
    #expect(counts.deviceCode == 1)

    model.cancelOnboarding()
    #expect(!model.isPresentingOnboarding)
    #expect(model.onboardingPhase == .configuration)
}

@Test @MainActor
func testedEnterpriseServerProceedsDirectlyToDeviceFlow() async throws {
    let transport = EnterpriseOnboardingTransport(installedVersion: "3.22.1")
    let deviceFlowClient = GitHubDeviceFlowClient(
        transport: transport,
        now: { Date(timeIntervalSince1970: 100_000) }
    )
    let waiter = GitHubDeviceAuthorizationWaiter(
        client: deviceFlowClient,
        sleeper: { _ in
            try await Task.sleep(nanoseconds: 60_000_000_000)
        }
    )
    let model = GitHubConnectionsRuntimeModel(
        profileStore: EnterpriseOnboardingProfileStore(),
        sessionCoordinator: GitHubConnectionSessionCoordinator(
            credentialStore: EnterpriseOnboardingCredentialStore()
        ),
        activityProvider: GitHubActivityProvider(
            workflowRunLoader: EnterpriseOnboardingWorkflowLoader()
        ),
        deviceFlowClient: deviceFlowClient,
        authorizationWaiter: waiter,
        enterpriseDiscovery: GitHubEnterpriseServerDiscoveryClient(
            transport: transport
        )
    )

    model.beginOnboarding(defaultClientID: "Iv1.enterprise-client")
    model.onboardingDraft = GitHubConnectionDraft(
        deploymentKind: .enterpriseServer,
        displayName: "Internal GitHub",
        serverURL: "https://github.internal.example",
        clientID: "Iv1.enterprise-client"
    )
    model.connectDraft()

    try await waitForDeviceAuthorizationPresentation(model)

    if case .enterpriseServerCompatibilityWarning = model.onboardingPhase {
        Issue.record("Tested GHES must not require compatibility confirmation")
    }

    let counts = await transport.counts()
    #expect(counts.meta == 1)
    #expect(counts.deviceCode == 1)

    model.cancelOnboarding()
}

@MainActor
private func waitForEnterpriseCompatibilityWarning(
    _ model: GitHubConnectionsRuntimeModel
) async throws {
    for _ in 0..<500 {
        if case .enterpriseServerCompatibilityWarning = model.onboardingPhase {
            return
        }
        if case let .failed(message) = model.onboardingPhase {
            Issue.record("Onboarding failed unexpectedly: \(message)")
            return
        }
        await Task.yield()
    }
    Issue.record("Timed out waiting for GHES compatibility warning")
}

@MainActor
private func waitForDeviceAuthorizationPresentation(
    _ model: GitHubConnectionsRuntimeModel
) async throws {
    for _ in 0..<500 {
        if case .waitingForAuthorization = model.onboardingPhase {
            return
        }
        if case let .failed(message) = model.onboardingPhase {
            Issue.record("Onboarding failed unexpectedly: \(message)")
            return
        }
        await Task.yield()
    }
    Issue.record("Timed out waiting for Device Flow authorization")
}

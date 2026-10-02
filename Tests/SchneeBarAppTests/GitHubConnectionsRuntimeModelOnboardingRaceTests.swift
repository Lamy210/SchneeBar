@testable import SchneeBar
import Foundation
import SchneeBarGitHub
import SchneeBarGitHubActivityProvider
import SchneeBarGitHubFeature
import Testing

private actor OnboardingRebindGate {
    private var started = false
    private var released = false
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseWaiters: [CheckedContinuation<Void, Never>] = []

    func markStartedAndWait() async {
        if !started {
            started = true
            let waiters = startWaiters
            startWaiters.removeAll()
            for waiter in waiters {
                waiter.resume()
            }
        }
        if released {
            return
        }
        await withCheckedContinuation { continuation in
            releaseWaiters.append(continuation)
        }
    }

    func waitUntilStarted() async {
        if started {
            return
        }
        await withCheckedContinuation { continuation in
            startWaiters.append(continuation)
        }
    }

    func release() {
        guard !released else { return }
        released = true
        let waiters = releaseWaiters
        releaseWaiters.removeAll()
        for waiter in waiters {
            waiter.resume()
        }
    }
}

private actor OnboardingRaceProfileStore: GitHubConnectionProfileStore {
    private var values: [UUID: GitHubConnectionProfile]

    init(_ profiles: [GitHubConnectionProfile]) {
        values = Dictionary(
            uniqueKeysWithValues: profiles.map { ($0.id, $0) }
        )
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

private actor OnboardingRaceCredentialStore: GitHubCredentialStore {
    private var values: [GitHubCredentialKey: GitHubCredential]
    private let blockedKey: GitHubCredentialKey
    private let gate = OnboardingRebindGate()

    init(
        existingKey: GitHubCredentialKey,
        existingCredential: GitHubCredential
    ) {
        values = [existingKey: existingCredential]
        blockedKey = existingKey
    }

    func load(for key: GitHubCredentialKey) async throws -> GitHubCredential? {
        if key == blockedKey {
            await gate.markStartedAndWait()
        }
        return values[key]
    }

    func save(
        _ credential: GitHubCredential,
        for key: GitHubCredentialKey
    ) async throws {
        values[key] = credential
    }

    func delete(for key: GitHubCredentialKey) async throws {
        values.removeValue(forKey: key)
    }

    func waitUntilTargetLoadStarts() async {
        await gate.waitUntilStarted()
    }

    func releaseTargetLoad() async {
        await gate.release()
    }

    func value(for key: GitHubCredentialKey) -> GitHubCredential? {
        values[key]
    }

    func count() -> Int {
        values.count
    }
}

private actor OnboardingRaceTransport: GitHubHTTPTransport {
    private var userRequestCount = 0

    func data(
        for request: URLRequest
    ) async throws -> (Data, HTTPURLResponse) {
        let path = request.url?.path ?? ""
        let method = request.httpMethod ?? "GET"

        let json: String
        if method == "POST", path == "/login/device/code" {
            json =
                #"{"device_code":"onboarding-device","user_code":"ONBOARD-CODE","verification_uri":"https://github.com/login/device","expires_in":900,"interval":1}"#
        } else if method == "POST", path == "/login/oauth/access_token" {
            json =
                #"{"access_token":"fresh-onboarding-token","token_type":"bearer"}"#
        } else if method == "GET", path == "/user" {
            userRequestCount += 1
            json = onboardingRaceUserJSON(
                id: 42,
                login: "reconnected-user"
            )
        } else if method == "GET", path == "/user/installations" {
            json = #"{"total_count":0,"installations":[]}"#
        } else {
            return try response(
                for: request,
                json: #"{"message":"unexpected request"}"#,
                statusCode: 500
            )
        }

        return try response(for: request, json: json)
    }

    func userRequests() -> Int {
        userRequestCount
    }

    private func response(
        for request: URLRequest,
        json: String,
        statusCode: Int = 200
    ) throws -> (Data, HTTPURLResponse) {
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
}

private struct OnboardingRaceWorkflowLoader: GitHubWorkflowRunLoading {
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

private let onboardingRaceNow = Date(timeIntervalSince1970: 60_000)

@Test @MainActor
func cancellingReconnectDuringRebindRollsBackProfileAndCredential() async throws {
    let original = try onboardingRaceProfile()
    let existingKey = original.credentialKey
    let existingCredential = GitHubCredential(
        accessToken: "existing-token",
        endpointIdentity: "https://github.com"
    )
    let profileStore = OnboardingRaceProfileStore([original])
    let credentialStore = OnboardingRaceCredentialStore(
        existingKey: existingKey,
        existingCredential: existingCredential
    )
    let transport = OnboardingRaceTransport()
    let deviceFlowClient = GitHubDeviceFlowClient(
        transport: transport,
        now: { onboardingRaceNow }
    )
    let coordinator = GitHubConnectionSessionCoordinator(
        credentialStore: credentialStore,
        accessClient: GitHubAccessClient(transport: transport),
        deviceFlowClient: deviceFlowClient,
        now: { onboardingRaceNow }
    )
    let model = GitHubConnectionsRuntimeModel(
        profileStore: profileStore,
        sessionCoordinator: coordinator,
        activityProvider: GitHubActivityProvider(
            workflowRunLoader: OnboardingRaceWorkflowLoader(),
            now: { onboardingRaceNow }
        ),
        deviceFlowClient: deviceFlowClient,
        authorizationWaiter: GitHubDeviceAuthorizationWaiter(
            client: deviceFlowClient,
            sleeper: { _ in }
        )
    )
    model.profiles = [original]
    model.statusByConnectionID[original.id] = .connected(
        repositoryCount: 0
    )

    model.beginOnboarding(defaultClientID: "test-client-id")
    model.onboardingDraft = GitHubConnectionDraft(
        deploymentKind: .githubDotCom,
        displayName: "GitHub.com",
        serverURL: "https://github.com",
        clientID: "test-client-id"
    )
    model.connectDraft()

    await credentialStore.waitUntilTargetLoadStarts()

    let savedBeforeCancellation = try #require(
        await profileStore.load(id: original.id)
    )
    #expect(savedBeforeCancellation.account.login == "reconnected-user")
    #expect(savedBeforeCancellation.id == original.id)

    model.cancelOnboarding()
    await credentialStore.releaseTargetLoad()

    try await waitForOnboardingRollback(
        profileStore: profileStore,
        credentialStore: credentialStore,
        original: original
    )

    #expect(model.profiles == [original])
    #expect(model.onboardingPhase == .configuration)
    #expect(!model.isPresentingOnboarding)
    #expect(try await profileStore.load(id: original.id) == original)
    #expect(
        await credentialStore.value(for: existingKey)
            == existingCredential
    )
    #expect(await credentialStore.count() == 1)
    #expect(await transport.userRequests() == 2)
}

private func onboardingRaceProfile() throws -> GitHubConnectionProfile {
    GitHubConnectionProfile(
        connection: GitHubConnection(
            id: UUID(
                uuidString:
                    "33000000-0000-0000-0000-000000000001"
            )!,
            displayName: "GitHub.com",
            deploymentKind: .githubDotCom,
            webBaseURL: try #require(
                URL(string: "https://github.com")
            )
        ),
        account: GitHubAccountIdentity(
            id: "42",
            login: "original-user"
        ),
        authenticationMethod: .deviceFlow,
        clientID: "test-client-id",
        repositorySelection: .selected([101, 202]),
        isEnabled: true,
        createdAt: Date(timeIntervalSince1970: 1_000),
        lastConnectedAt: Date(timeIntervalSince1970: 2_000)
    )
}

private func onboardingRaceUserJSON(
    id: Int,
    login: String
) -> String {
    #"{"id":\#(id),"login":"\#(login)","name":"Test User","avatar_url":null}"#
}

@MainActor
private func waitForOnboardingRollback(
    profileStore: OnboardingRaceProfileStore,
    credentialStore: OnboardingRaceCredentialStore,
    original: GitHubConnectionProfile
) async throws {
    for _ in 0 ..< 1_000 {
        let storedProfile = try await profileStore.load(id: original.id)
        let credentialCount = await credentialStore.count()
        if storedProfile == original, credentialCount == 1 {
            return
        }
        await Task.yield()
    }
    Issue.record("Timed out waiting for onboarding rollback")
}

@testable import SchneeBar
import Foundation
import SchneeBarGitHub
import SchneeBarGitHubActivityProvider
import SchneeBarGitHubFeature
import Testing

private actor OnboardingSaveGate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        if isOpen {
            return
        }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    func open() {
        guard !isOpen else { return }
        isOpen = true
        let continuations = waiters
        waiters.removeAll()
        for continuation in continuations {
            continuation.resume()
        }
    }
}

private actor OnboardingSaveRaceProfileStore: GitHubConnectionProfileStore {
    private var values: [UUID: GitHubConnectionProfile] = [:]
    private let saveStarted = OnboardingSaveGate()
    private let saveRelease = OnboardingSaveGate()
    private let blockedSaveCompleted = OnboardingSaveGate()

    func loadAll() async throws -> [GitHubConnectionProfile] {
        Array(values.values)
    }

    func load(id: UUID) async throws -> GitHubConnectionProfile? {
        values[id]
    }

    func save(_ profile: GitHubConnectionProfile) async throws {
        await saveStarted.open()
        await saveRelease.wait()
        values[profile.id] = profile
        await blockedSaveCompleted.open()
    }

    func delete(id: UUID) async throws {
        values.removeValue(forKey: id)
    }

    func waitUntilSaveStarts() async {
        await saveStarted.wait()
    }

    func releaseSave() async {
        await saveRelease.open()
    }

    func waitUntilBlockedSaveCompletes() async {
        await blockedSaveCompleted.wait()
    }

    func count() -> Int {
        values.count
    }
}

private actor OnboardingSaveRaceCredentialStore: GitHubCredentialStore {
    private var values: [GitHubCredentialKey: GitHubCredential] = [:]

    func load(for key: GitHubCredentialKey) async throws -> GitHubCredential? {
        values[key]
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

    func count() -> Int {
        values.count
    }
}

private actor OnboardingSaveRaceTransport: GitHubHTTPTransport {
    func data(
        for request: URLRequest
    ) async throws -> (Data, HTTPURLResponse) {
        let method = request.httpMethod ?? "GET"
        let path = request.url?.path ?? ""

        let json: String
        if method == "POST", path == "/login/device/code" {
            json =
                #"{"device_code":"save-race-device","user_code":"SAVE-RACE","verification_uri":"https://github.com/login/device","expires_in":900,"interval":1}"#
        } else if method == "POST",
                  path == "/login/oauth/access_token"
        {
            json =
                #"{"access_token":"save-race-access","token_type":"bearer"}"#
        } else if method == "GET", path == "/user" {
            json =
                #"{"id":42,"login":"octocat","name":"Test User","avatar_url":null}"#
        } else if method == "GET", path == "/user/installations" {
            json = #"{"total_count":0,"installations":[]}"#
        } else {
            return try response(
                request,
                json: #"{"message":"unexpected request"}"#,
                statusCode: 500
            )
        }

        return try response(request, json: json)
    }

    private func response(
        _ request: URLRequest,
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

private struct OnboardingSaveRaceWorkflowLoader: GitHubWorkflowRunLoading {
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

private let onboardingSaveRaceNow = Date(
    timeIntervalSince1970: 90_000
)

@Test @MainActor
func cancellingOnboardingDuringProfileSaveRollsBackNewConnection() async throws {
    let profileStore = OnboardingSaveRaceProfileStore()
    let credentialStore = OnboardingSaveRaceCredentialStore()
    let transport = OnboardingSaveRaceTransport()
    let deviceFlowClient = GitHubDeviceFlowClient(
        transport: transport,
        now: { onboardingSaveRaceNow }
    )
    let model = GitHubConnectionsRuntimeModel(
        profileStore: profileStore,
        sessionCoordinator: GitHubConnectionSessionCoordinator(
            credentialStore: credentialStore,
            accessClient: GitHubAccessClient(transport: transport),
            deviceFlowClient: deviceFlowClient,
            now: { onboardingSaveRaceNow }
        ),
        activityProvider: GitHubActivityProvider(
            workflowRunLoader: OnboardingSaveRaceWorkflowLoader(),
            now: { onboardingSaveRaceNow }
        ),
        deviceFlowClient: deviceFlowClient,
        authorizationWaiter: GitHubDeviceAuthorizationWaiter(
            client: deviceFlowClient,
            sleeper: { _ in }
        ),
        now: { onboardingSaveRaceNow }
    )

    model.beginOnboarding(defaultClientID: "test-client-id")
    model.onboardingDraft = GitHubConnectionDraft(
        deploymentKind: .githubDotCom,
        displayName: "GitHub.com",
        serverURL: "https://github.com",
        clientID: "test-client-id"
    )
    model.connectDraft()

    await profileStore.waitUntilSaveStarts()
    #expect(await credentialStore.count() == 1)

    model.cancelOnboarding()
    await profileStore.releaseSave()
    await profileStore.waitUntilBlockedSaveCompletes()

    await waitForOnboardingSaveRollback(
        profileStore: profileStore,
        credentialStore: credentialStore
    )

    #expect(model.profiles.isEmpty)
    #expect(await profileStore.count() == 0)
    #expect(await credentialStore.count() == 0)
    #expect(model.onboardingPhase == .configuration)
    #expect(!model.isPresentingOnboarding)
}

private func waitForOnboardingSaveRollback(
    profileStore: OnboardingSaveRaceProfileStore,
    credentialStore: OnboardingSaveRaceCredentialStore
) async {
    for _ in 0 ..< 1_000 {
        if await profileStore.count() == 0,
           await credentialStore.count() == 0
        {
            return
        }
        await Task.yield()
    }
    Issue.record(
        "Timed out waiting for cancelled onboarding save rollback"
    )
}

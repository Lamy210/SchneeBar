@testable import SchneeBar
import Foundation
import SchneeBarGitHub
import SchneeBarGitHubActivityProvider
import Testing

private actor RuntimeRaceGate {
    private var open = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        if open { return }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    func release() {
        guard !open else { return }
        open = true
        let continuations = waiters
        waiters.removeAll()
        continuations.forEach { $0.resume() }
    }
}

private actor RuntimeRaceProfileStore: GitHubConnectionProfileStore {
    private var values: [UUID: GitHubConnectionProfile]

    init(_ profile: GitHubConnectionProfile) {
        values = [profile.id: profile]
    }

    func loadAll() async throws -> [GitHubConnectionProfile] { Array(values.values) }
    func load(id: UUID) async throws -> GitHubConnectionProfile? { values[id] }
    func save(_ profile: GitHubConnectionProfile) async throws { values[profile.id] = profile }
    func delete(id: UUID) async throws { values.removeValue(forKey: id) }
}

private actor RuntimeRaceCredentialStore: GitHubCredentialStore {
    private var values: [GitHubCredentialKey: GitHubCredential] = [:]

    func load(for key: GitHubCredentialKey) async throws -> GitHubCredential? { values[key] }
    func save(_ credential: GitHubCredential, for key: GitHubCredentialKey) async throws {
        values[key] = credential
    }
    func delete(for key: GitHubCredentialKey) async throws { values.removeValue(forKey: key) }
}

private actor RuntimeRaceTransport: GitHubHTTPTransport {
    private let staleRefreshStarted = RuntimeRaceGate()
    private let staleRefreshRelease = RuntimeRaceGate()
    private var userRequestCount = 0

    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let path = request.url?.path ?? ""
        let method = request.httpMethod ?? "GET"

        if method == "POST", path == "/login/device/code" {
            return try response(
                for: request,
                json: #"{"device_code":"race-device","user_code":"RACE-CODE","verification_uri":"https://github.com/login/device","expires_in":900,"interval":1}"#
            )
        }

        if method == "POST", path == "/login/oauth/access_token" {
            return try response(
                for: request,
                json: #"{"access_token":"test-recovery-token","token_type":"bearer"}"#
            )
        }

        if method == "GET", path == "/user" {
            userRequestCount += 1
            if userRequestCount == 1 {
                await staleRefreshStarted.release()
                await staleRefreshRelease.wait()
                return try response(
                    for: request,
                    json: runtimeRaceUserJSON(login: "stale-login")
                )
            }

            return try response(
                for: request,
                json: runtimeRaceUserJSON(login: "recovered-login")
            )
        }

        if method == "GET", path == "/user/installations" {
            return try response(
                for: request,
                json: #"{"total_count":0,"installations":[]}"#
            )
        }

        return try response(
            for: request,
            json: #"{"message":"unexpected request"}"#,
            statusCode: 500
        )
    }

    func waitUntilStaleRefreshStarts() async {
        await staleRefreshStarted.wait()
    }

    func releaseStaleRefresh() async {
        await staleRefreshRelease.release()
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

private struct RuntimeRaceWorkflowLoader: GitHubWorkflowRunLoading {
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

private let runtimeRaceNow = Date(timeIntervalSince1970: 50_000)

@Test @MainActor
func staleRefreshCannotOverwriteSuccessfulRecovery() async throws {
    let profile = try runtimeRaceProfile()
    let profileStore = RuntimeRaceProfileStore(profile)
    let credentialStore = RuntimeRaceCredentialStore()
    let key = profile.credentialKey
    try await credentialStore.save(
        GitHubCredential(accessToken: "test-stale-token"),
        for: key
    )

    let transport = RuntimeRaceTransport()
    let deviceFlowClient = GitHubDeviceFlowClient(
        transport: transport,
        now: { runtimeRaceNow }
    )
    let coordinator = GitHubConnectionSessionCoordinator(
        credentialStore: credentialStore,
        accessClient: GitHubAccessClient(transport: transport),
        deviceFlowClient: deviceFlowClient,
        now: { runtimeRaceNow }
    )
    let model = GitHubConnectionsRuntimeModel(
        profileStore: profileStore,
        sessionCoordinator: coordinator,
        activityProvider: GitHubActivityProvider(
            workflowRunLoader: RuntimeRaceWorkflowLoader(),
            now: { runtimeRaceNow }
        ),
        deviceFlowClient: deviceFlowClient,
        authorizationWaiter: GitHubDeviceAuthorizationWaiter(
            client: deviceFlowClient,
            sleeper: { _ in }
        )
    )
    model.profiles = [profile]
    model.statusByConnectionID[profile.id] = .authenticationRequired

    let staleRefresh = Task { @MainActor in
        await model.refresh(profileID: profile.id)
    }
    await transport.waitUntilStaleRefreshStarts()

    model.beginRecovery(profileID: profile.id)
    await waitUntilRuntimeRaceRecoveryFinishes(model)

    let recoveredBeforeRelease = try #require(
        model.profiles.first(where: { $0.id == profile.id })
    )
    #expect(recoveredBeforeRelease.account.login == "recovered-login")
    #expect(model.statusByConnectionID[profile.id] == .connected(repositoryCount: 0))

    await transport.releaseStaleRefresh()
    await staleRefresh.value

    let finalProfile = try #require(
        model.profiles.first(where: { $0.id == profile.id })
    )
    #expect(finalProfile.account.login == "recovered-login")
    #expect(finalProfile.repositorySelection == profile.repositorySelection)
    #expect(model.statusByConnectionID[profile.id] == .connected(repositoryCount: 0))
    #expect(try await profileStore.load(id: profile.id)?.account.login == "recovered-login")
    #expect(try await credentialStore.load(for: key)?.accessToken == "test-recovery-token")
}

private func runtimeRaceProfile() throws -> GitHubConnectionProfile {
    GitHubConnectionProfile(
        connection: GitHubConnection(
            id: UUID(uuidString: "32000000-0000-0000-0000-000000000001")!,
            displayName: "GitHub.com",
            deploymentKind: .githubDotCom,
            webBaseURL: try #require(URL(string: "https://github.com"))
        ),
        account: GitHubAccountIdentity(id: "42", login: "original-login"),
        authenticationMethod: .deviceFlow,
        clientID: "test-client-id",
        repositorySelection: .selected([101, 202]),
        isEnabled: true,
        createdAt: Date(timeIntervalSince1970: 1_000),
        lastConnectedAt: Date(timeIntervalSince1970: 2_000)
    )
}

private func runtimeRaceUserJSON(login: String) -> String {
    #"{"id":42,"login":"\#(login)","name":"Test User","avatar_url":null}"#
}

@MainActor
private func waitUntilRuntimeRaceRecoveryFinishes(
    _ model: GitHubConnectionsRuntimeModel
) async {
    for _ in 0..<1_000 {
        if model.recoveringConnectionID == nil {
            return
        }
        if case let .failed(message) = model.recoveryPhase {
            Issue.record("Recovery failed unexpectedly: \(message)")
            return
        }
        await Task.yield()
    }
    Issue.record("Timed out waiting for recovery to finish")
}

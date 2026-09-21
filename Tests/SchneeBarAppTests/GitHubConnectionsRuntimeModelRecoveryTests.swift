@testable import SchneeBar
import Foundation
import SchneeBarGitHub
import SchneeBarGitHubActivityProvider
import SchneeBarGitHubFeature
import Testing

private actor RuntimeProfileStore: GitHubConnectionProfileStore {
    private var values: [UUID: GitHubConnectionProfile]

    init(_ profiles: [GitHubConnectionProfile] = []) {
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

private actor RuntimeCredentialStore: GitHubCredentialStore {
    private var values: [GitHubCredentialKey: GitHubCredential] = [:]

    func load(for key: GitHubCredentialKey) async throws -> GitHubCredential? {
        values[key]
    }

    func save(_ credential: GitHubCredential, for key: GitHubCredentialKey) async throws {
        values[key] = credential
    }

    func delete(for key: GitHubCredentialKey) async throws {
        values.removeValue(forKey: key)
    }
}

private struct RuntimeHTTPResponse: Sendable {
    let json: String
    let statusCode: Int

    init(_ json: String, statusCode: Int = 200) {
        self.json = json
        self.statusCode = statusCode
    }
}

private actor RuntimeQueueTransport: GitHubHTTPTransport {
    private var responses: [RuntimeHTTPResponse]

    init(_ responses: [RuntimeHTTPResponse]) {
        self.responses = responses
    }

    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let response = responses.isEmpty
            ? RuntimeHTTPResponse(#"{"message":"Unexpected request"}"#, statusCode: 500)
            : responses.removeFirst()
        let httpResponse = try #require(
            HTTPURLResponse(
                url: request.url!,
                statusCode: response.statusCode,
                httpVersion: "HTTP/1.1",
                headerFields: nil
            )
        )
        return (Data(response.json.utf8), httpResponse)
    }
}

private struct EmptyWorkflowRunLoader: GitHubWorkflowRunLoading {
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

private let runtimeNow = Date(timeIntervalSince1970: 40_000)

@Test @MainActor
func successfulRecoveryPreservesProfileConfiguration() async throws {
    var original = try runtimeProfile(
        login: "old-login",
        selectedRepositoryIDs: [11, 22],
        isEnabled: true
    )
    original.lastEnterpriseMetadataCheckAt = Date(timeIntervalSince1970: 35_000)
    let fixture = runtimeFixture(
        profiles: [original],
        responses: successfulRecoveryResponses(id: 42, login: "renamed-user")
    )
    fixture.model.profiles = [original]
    fixture.model.statusByConnectionID[original.id] = .authenticationRequired

    fixture.model.beginRecovery(profileID: original.id)
    try await waitForRecoveryToFinish(fixture.model)

    let updated = try #require(
        fixture.model.profiles.first(where: { $0.id == original.id })
    )
    #expect(updated.id == original.id)
    #expect(updated.account.id == original.account.id)
    #expect(updated.account.login == "renamed-user")
    #expect(updated.repositorySelection == original.repositorySelection)
    #expect(updated.isEnabled == original.isEnabled)
    #expect(updated.createdAt == original.createdAt)
    #expect(updated.authenticationMethod == original.authenticationMethod)
    #expect(updated.clientID == original.clientID)
    #expect(updated.lastConnectedAt != original.lastConnectedAt)
    #expect(
        updated.lastEnterpriseMetadataCheckAt
            == original.lastEnterpriseMetadataCheckAt
    )
    #expect(fixture.model.statusByConnectionID[original.id] == .connected(repositoryCount: 0))
}

@Test @MainActor
func wrongAccountRecoveryDoesNotCreateOrReplaceProfile() async throws {
    let original = try runtimeProfile(login: "expected-user")
    let fixture = runtimeFixture(
        profiles: [original],
        responses: [
            RuntimeHTTPResponse(deviceAuthorizationJSON()),
            RuntimeHTTPResponse(accessTokenJSON()),
            RuntimeHTTPResponse(userJSON(id: 99, login: "other-user")),
        ]
    )
    fixture.model.profiles = [original]
    fixture.model.statusByConnectionID[original.id] = .authenticationRequired

    fixture.model.beginRecovery(profileID: original.id)
    try await waitForRecoveryFailure(fixture.model)

    #expect(fixture.model.profiles == [original])
    #expect(fixture.model.statusByConnectionID[original.id] == .authenticationRequired)
    #expect(fixture.model.recoveringConnectionID == original.id)
    #expect(
        fixture.model.recoveryPhase
            == .failed(
                message: "GitHub authorized a different account. Sign in as @expected-user and try again."
            )
    )
}

@Test @MainActor
func recoveryWorksWhileMonitoringIsDisabled() async throws {
    let original = try runtimeProfile(login: "old-login", isEnabled: false)
    let fixture = runtimeFixture(
        profiles: [original],
        responses: successfulRecoveryResponses(id: 42, login: "renamed-user")
    )
    fixture.model.profiles = [original]
    fixture.model.statusByConnectionID[original.id] = .authenticationRequired

    fixture.model.beginRecovery(profileID: original.id)
    try await waitForRecoveryToFinish(fixture.model)

    let updated = try #require(fixture.model.profiles.first)
    #expect(updated.isEnabled == false)
    #expect(updated.account.login == "renamed-user")
    #expect(fixture.model.statusByConnectionID[original.id] == .disabled)
}

@Test @MainActor
func recoveryMissingClientIDFailsWithoutDeletingProfile() async throws {
    var original = try runtimeProfile(login: "expected-user")
    original.clientID = nil
    let fixture = runtimeFixture(profiles: [original], responses: [])
    fixture.model.profiles = [original]
    fixture.model.statusByConnectionID[original.id] = .authenticationRequired

    fixture.model.beginRecovery(profileID: original.id)
    try await waitForRecoveryFailure(fixture.model)

    #expect(
        fixture.model.recoveryPhase
            == .failed(
                message: "This saved GitHub connection is missing the client ID required for re-authentication. Add the connection again to repair it."
            )
    )
    #expect(fixture.model.profiles == [original])
    #expect(fixture.model.statusByConnectionID[original.id] == .authenticationRequired)
}

@Test @MainActor
func recoveringAccountADoesNotChangeAccountBOnSameEndpoint() async throws {
    let accountA = try runtimeProfile(
        id: UUID(uuidString: "30000000-0000-0000-0000-000000000001")!,
        accountID: "42",
        login: "account-a"
    )
    let accountB = try runtimeProfile(
        id: UUID(uuidString: "30000000-0000-0000-0000-000000000002")!,
        accountID: "99",
        login: "account-b"
    )
    let fixture = runtimeFixture(
        profiles: [accountA, accountB],
        responses: successfulRecoveryResponses(id: 42, login: "account-a-renamed")
    )
    fixture.model.profiles = [accountA, accountB]
    fixture.model.statusByConnectionID[accountA.id] = .authenticationRequired
    fixture.model.statusByConnectionID[accountB.id] = .connected(repositoryCount: 0)

    fixture.model.beginRecovery(profileID: accountA.id)
    try await waitForRecoveryToFinish(fixture.model)

    let recoveredA = try #require(fixture.model.profiles.first(where: { $0.id == accountA.id }))
    let unchangedB = try #require(fixture.model.profiles.first(where: { $0.id == accountB.id }))
    #expect(recoveredA.account.login == "account-a-renamed")
    #expect(unchangedB == accountB)
}

@MainActor
private struct RuntimeFixture {
    let model: GitHubConnectionsRuntimeModel
    let profileStore: RuntimeProfileStore
    let credentialStore: RuntimeCredentialStore
}

@MainActor
private func runtimeFixture(
    profiles: [GitHubConnectionProfile],
    responses: [RuntimeHTTPResponse]
) -> RuntimeFixture {
    let profileStore = RuntimeProfileStore(profiles)
    let credentialStore = RuntimeCredentialStore()
    let transport = RuntimeQueueTransport(responses)
    let deviceFlowClient = GitHubDeviceFlowClient(
        transport: transport,
        now: { runtimeNow }
    )
    let waiter = GitHubDeviceAuthorizationWaiter(
        client: deviceFlowClient,
        sleeper: { _ in }
    )
    let sessionCoordinator = GitHubConnectionSessionCoordinator(
        credentialStore: credentialStore,
        accessClient: GitHubAccessClient(transport: transport),
        deviceFlowClient: deviceFlowClient,
        now: { runtimeNow }
    )
    let activityProvider = GitHubActivityProvider(
        workflowRunLoader: EmptyWorkflowRunLoader(),
        now: { runtimeNow }
    )
    let model = GitHubConnectionsRuntimeModel(
        profileStore: profileStore,
        sessionCoordinator: sessionCoordinator,
        activityProvider: activityProvider,
        deviceFlowClient: deviceFlowClient,
        authorizationWaiter: waiter
    )
    return RuntimeFixture(
        model: model,
        profileStore: profileStore,
        credentialStore: credentialStore
    )
}

private func runtimeProfile(
    id: UUID = UUID(uuidString: "30000000-0000-0000-0000-000000000042")!,
    accountID: String = "42",
    login: String,
    selectedRepositoryIDs: Set<Int64> = [11],
    isEnabled: Bool = true
) throws -> GitHubConnectionProfile {
    GitHubConnectionProfile(
        connection: GitHubConnection(
            id: id,
            displayName: "GitHub.com",
            deploymentKind: .githubDotCom,
            webBaseURL: try #require(URL(string: "https://github.com"))
        ),
        account: GitHubAccountIdentity(id: accountID, login: login),
        authenticationMethod: .deviceFlow,
        clientID: "test-client-id",
        repositorySelection: .selected(selectedRepositoryIDs),
        isEnabled: isEnabled,
        createdAt: Date(timeIntervalSince1970: 1_000),
        lastConnectedAt: Date(timeIntervalSince1970: 2_000)
    )
}

private func successfulRecoveryResponses(id: Int, login: String) -> [RuntimeHTTPResponse] {
    [
        RuntimeHTTPResponse(deviceAuthorizationJSON()),
        RuntimeHTTPResponse(accessTokenJSON()),
        RuntimeHTTPResponse(userJSON(id: id, login: login)),
        RuntimeHTTPResponse(userJSON(id: id, login: login)),
        RuntimeHTTPResponse(#"{"total_count":0,"installations":[]}"#),
    ]
}

private func deviceAuthorizationJSON() -> String {
    #"{"device_code":"test-device","user_code":"ABCD-EFGH","verification_uri":"https://github.com/login/device","expires_in":900,"interval":1}"#
}

private func accessTokenJSON() -> String {
    #"{"access_token":"test-access-token","token_type":"bearer"}"#
}

private func userJSON(id: Int, login: String) -> String {
    #"{"id":\#(id),"login":"\#(login)","name":"Test User","avatar_url":null}"#
}

@MainActor
private func waitForRecoveryToFinish(
    _ model: GitHubConnectionsRuntimeModel
) async throws {
    for _ in 0..<500 {
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

@MainActor
private func waitForRecoveryFailure(
    _ model: GitHubConnectionsRuntimeModel
) async throws {
    for _ in 0..<500 {
        if case .failed = model.recoveryPhase {
            return
        }
        await Task.yield()
    }
    Issue.record("Timed out waiting for recovery failure")
}

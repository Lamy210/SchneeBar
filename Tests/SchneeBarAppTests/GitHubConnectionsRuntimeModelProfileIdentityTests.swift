@testable import SchneeBar
import Foundation
import SchneeBarGitHub
import SchneeBarGitHubActivityProvider
import Testing

private actor ProfileCollisionStore: GitHubConnectionProfileStore {
    private var profiles: [GitHubConnectionProfile]

    init(_ profiles: [GitHubConnectionProfile]) {
        self.profiles = profiles
    }

    func loadAll() async throws -> [GitHubConnectionProfile] {
        profiles
    }

    func load(id: UUID) async throws -> GitHubConnectionProfile? {
        profiles.first(where: { $0.id == id })
    }

    func save(_ profile: GitHubConnectionProfile) async throws {
        profiles.removeAll(where: { $0.id == profile.id })
        profiles.append(profile)
    }

    func delete(id: UUID) async throws {
        profiles.removeAll(where: { $0.id == id })
    }
}

private actor ProfileCollisionCredentialStore: GitHubCredentialStore {
    func load(
        for key: GitHubCredentialKey
    ) async throws -> GitHubCredential? {
        nil
    }

    func save(
        _ credential: GitHubCredential,
        for key: GitHubCredentialKey
    ) async throws {}

    func delete(for key: GitHubCredentialKey) async throws {}
}

private actor ProfileCollisionTransport: GitHubHTTPTransport {
    private var count = 0

    func data(
        for request: URLRequest
    ) async throws -> (Data, HTTPURLResponse) {
        count += 1
        let response = try #require(
            HTTPURLResponse(
                url: request.url!,
                statusCode: 500,
                httpVersion: "HTTP/1.1",
                headerFields: nil
            )
        )
        return (
            Data(#"{"message":"unexpected request"}"#.utf8),
            response
        )
    }

    func requestCount() -> Int {
        count
    }
}

private actor ProfileCollisionRecoveryCredentialStore:
    GitHubCredentialStore
{
    private var values: [GitHubCredentialKey: GitHubCredential]

    init(
        values: [GitHubCredentialKey: GitHubCredential] = [:]
    ) {
        self.values = values
    }

    func load(
        for key: GitHubCredentialKey
    ) async throws -> GitHubCredential? {
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
}

private actor ProfileCollisionRecoveryTransport: GitHubHTTPTransport {
    private var count = 0

    func data(
        for request: URLRequest
    ) async throws -> (Data, HTTPURLResponse) {
        count += 1
        let path = request.url?.path ?? ""

        let json: String
        switch path {
        case "/user":
            json =
                #"{"id":42,"login":"renamed-login","name":null,"avatar_url":null}"#
        case "/user/installations":
            json = #"{"total_count":0,"installations":[]}"#
        default:
            return try response(
                for: request,
                json: #"{"message":"unexpected request"}"#,
                statusCode: 500
            )
        }

        return try response(
            for: request,
            json: json,
            statusCode: 200
        )
    }

    func requestCount() -> Int {
        count
    }

    private func response(
        for request: URLRequest,
        json: String,
        statusCode: Int
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

private struct ProfileCollisionWorkflowLoader: GitHubWorkflowRunLoading {
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
func loadQuarantinesAmbiguousProfileIdentityWithoutRefreshing() async throws {
    let first = try profileCollisionProfile(
        id: UUID(
            uuidString: "77000000-0000-0000-0000-000000000001"
        )!,
        webURL: "https://github.com",
        login: "old-login"
    )
    let second = try profileCollisionProfile(
        id: UUID(
            uuidString: "77000000-0000-0000-0000-000000000002"
        )!,
        webURL: "https://GITHUB.COM/",
        login: "renamed-login"
    )
    let profileStore = ProfileCollisionStore([first, second])
    let credentialStore = ProfileCollisionCredentialStore()
    let transport = ProfileCollisionTransport()
    let coordinator = GitHubConnectionSessionCoordinator(
        credentialStore: credentialStore,
        accessClient: GitHubAccessClient(transport: transport)
    )
    let model = GitHubConnectionsRuntimeModel(
        profileStore: profileStore,
        sessionCoordinator: coordinator,
        activityProvider: GitHubActivityProvider(
            workflowRunLoader: ProfileCollisionWorkflowLoader()
        )
    )

    await model.load()

    #expect(Set(model.profiles.map(\.id)) == Set([first.id, second.id]))
    #expect(model.statusByConnectionID[first.id] == .unavailable)
    #expect(model.statusByConnectionID[second.id] == .unavailable)
    #expect(await transport.requestCount() == 0)
}

@Test @MainActor
func quarantinedProfileBlocksManualNetworkAndMutableActions() async throws {
    let first = try profileCollisionProfile(
        id: UUID(
            uuidString: "77000000-0000-0000-0000-000000000011"
        )!,
        webURL: "https://github.com",
        login: "old-login"
    )
    let second = try profileCollisionProfile(
        id: UUID(
            uuidString: "77000000-0000-0000-0000-000000000012"
        )!,
        webURL: "https://GITHUB.COM/",
        login: "renamed-login"
    )
    let profileStore = ProfileCollisionStore([first, second])
    let credentialStore = ProfileCollisionCredentialStore()
    let transport = ProfileCollisionTransport()
    let deviceFlowClient = GitHubDeviceFlowClient(
        transport: transport
    )
    let model = GitHubConnectionsRuntimeModel(
        profileStore: profileStore,
        sessionCoordinator: GitHubConnectionSessionCoordinator(
            credentialStore: credentialStore,
            accessClient: GitHubAccessClient(transport: transport)
        ),
        activityProvider: GitHubActivityProvider(
            workflowRunLoader: ProfileCollisionWorkflowLoader()
        ),
        deviceFlowClient: deviceFlowClient,
        authorizationWaiter: GitHubDeviceAuthorizationWaiter(
            client: deviceFlowClient,
            sleeper: { _ in }
        )
    )

    await model.load()
    await model.refresh(profileID: first.id)
    model.setEnabled(false, profileID: first.id)
    let selectionSaved = await model.saveRepositorySelection(
        profileID: first.id,
        mode: .selected,
        selectedRepositoryIDs: [101]
    )
    model.beginRecovery(profileID: first.id)

    #expect(await transport.requestCount() == 0)
    #expect(selectionSaved == false)
    #expect(
        model.profiles.first(where: { $0.id == first.id })?
            .isEnabled == true
    )
    #expect(
        model.profiles.first(where: { $0.id == first.id })?
            .repositorySelection == .allAccessible
    )
    #expect(model.statusByConnectionID[first.id] == .unavailable)
    guard case .failed = model.recoveryPhase else {
        Issue.record("Expected quarantined recovery to fail locally")
        return
    }
}

@Test @MainActor
func disconnectingDuplicateReleasesAndRefreshesRemainingProfile() async throws {
    let first = try profileCollisionProfile(
        id: UUID(
            uuidString: "77000000-0000-0000-0000-000000000021"
        )!,
        webURL: "https://github.com",
        login: "old-login"
    )
    let second = try profileCollisionProfile(
        id: UUID(
            uuidString: "77000000-0000-0000-0000-000000000022"
        )!,
        webURL: "https://GITHUB.COM/",
        login: "renamed-login"
    )
    let profileStore = ProfileCollisionStore([first, second])
    let secondKey = GitHubCredentialKey(
        connectionID: second.id,
        accountID: second.account.id
    )
    let credentialStore = ProfileCollisionRecoveryCredentialStore(
        values: [
            secondKey: GitHubCredential(
                accessToken: "remaining-token",
                endpointIdentity: "https://github.com"
            ),
        ]
    )
    let transport = ProfileCollisionRecoveryTransport()
    let model = GitHubConnectionsRuntimeModel(
        profileStore: profileStore,
        sessionCoordinator: GitHubConnectionSessionCoordinator(
            credentialStore: credentialStore,
            accessClient: GitHubAccessClient(transport: transport)
        ),
        activityProvider: GitHubActivityProvider(
            workflowRunLoader: ProfileCollisionWorkflowLoader()
        )
    )

    await model.load()

    #expect(await transport.requestCount() == 0)
    #expect(model.statusByConnectionID[first.id] == .unavailable)
    #expect(model.statusByConnectionID[second.id] == .unavailable)

    await model.disconnect(profileID: first.id)
    await waitForReleasedProfileRefresh(
        model: model,
        profileID: second.id
    )

    #expect(model.profiles.map(\.id) == [second.id])
    #expect(
        model.statusByConnectionID[second.id]
            == .connected(repositoryCount: 0)
    )
    #expect(await transport.requestCount() > 0)
    let persistedProfiles = try await profileStore.loadAll()
    #expect(persistedProfiles.map(\.id) == [second.id])
}

@MainActor
private func waitForReleasedProfileRefresh(
    model: GitHubConnectionsRuntimeModel,
    profileID: UUID
) async {
    for _ in 0 ..< 1_000 {
        if model.statusByConnectionID[profileID]
            == .connected(repositoryCount: 0)
        {
            return
        }
        await Task.yield()
    }
    Issue.record("Timed out waiting for released profile refresh")
}

private func profileCollisionProfile(
    id: UUID,
    webURL: String,
    login: String
) throws -> GitHubConnectionProfile {
    GitHubConnectionProfile(
        connection: GitHubConnection(
            id: id,
            displayName: "GitHub.com",
            deploymentKind: .githubDotCom,
            webBaseURL: try #require(URL(string: webURL))
        ),
        account: GitHubAccountIdentity(
            id: "42",
            login: login
        ),
        authenticationMethod: .deviceFlow,
        clientID: "test-client-id"
    )
}

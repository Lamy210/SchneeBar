@testable import SchneeBar
import Foundation
import SchneeBarGitHub
import SchneeBarGitHubActivityProvider
import SchneeBarGitHubFeature
import Testing

private actor EnablePersistenceGate {
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

private actor EnablePersistenceEvents {
    private var events: [String] = []

    func record(_ event: String) {
        events.append(event)
    }

    func snapshot() -> [String] {
        events
    }
}

private actor EnablePersistenceProfileStore: GitHubConnectionProfileStore {
    private var values: [UUID: GitHubConnectionProfile]
    private var isFirstSave = true
    private let events: EnablePersistenceEvents
    private let firstSaveStarted = EnablePersistenceGate()
    private let firstSaveRelease = EnablePersistenceGate()

    init(
        _ profile: GitHubConnectionProfile,
        events: EnablePersistenceEvents
    ) {
        values = [profile.id: profile]
        self.events = events
    }

    func loadAll() async throws -> [GitHubConnectionProfile] {
        Array(values.values)
    }

    func load(id: UUID) async throws -> GitHubConnectionProfile? {
        values[id]
    }

    func save(_ profile: GitHubConnectionProfile) async throws {
        let shouldYield = isFirstSave
        isFirstSave = false
        await events.record("profile-save-start")
        if shouldYield {
            await firstSaveStarted.open()
            await firstSaveRelease.wait()
        }
        values[profile.id] = profile
        await events.record("profile-save-end")
    }

    func delete(id: UUID) async throws {
        values.removeValue(forKey: id)
    }

    func waitUntilFirstSaveStarts() async {
        await firstSaveStarted.wait()
    }

    func releaseFirstSave() async {
        await firstSaveRelease.open()
    }

    func value(for id: UUID) -> GitHubConnectionProfile? {
        values[id]
    }
}

private enum EnablePersistenceFailure: Error {
    case save
}

private actor FailingEnableProfileStore: GitHubConnectionProfileStore {
    private var profile: GitHubConnectionProfile

    init(_ profile: GitHubConnectionProfile) {
        self.profile = profile
    }

    func loadAll() async throws -> [GitHubConnectionProfile] {
        [profile]
    }

    func load(id: UUID) async throws -> GitHubConnectionProfile? {
        profile.id == id ? profile : nil
    }

    func save(_ profile: GitHubConnectionProfile) async throws {
        throw EnablePersistenceFailure.save
    }

    func delete(id: UUID) async throws {}
}

private actor EnablePersistenceCredentialStore: GitHubCredentialStore {
    private let key: GitHubCredentialKey
    private let credential: GitHubCredential
    private let events: EnablePersistenceEvents?

    init(
        key: GitHubCredentialKey,
        credential: GitHubCredential,
        events: EnablePersistenceEvents? = nil
    ) {
        self.key = key
        self.credential = credential
        self.events = events
    }

    func load(for key: GitHubCredentialKey) async throws -> GitHubCredential? {
        if key == self.key {
            await events?.record("credential-load")
            return credential
        }
        return nil
    }

    func save(
        _ credential: GitHubCredential,
        for key: GitHubCredentialKey
    ) async throws {}

    func delete(for key: GitHubCredentialKey) async throws {}
}

private actor EnablePersistenceTransport: GitHubHTTPTransport {
    func data(
        for request: URLRequest
    ) async throws -> (Data, HTTPURLResponse) {
        let path = request.url?.path ?? ""
        let json: String
        if path == "/user" {
            json =
                #"{"id":42,"login":"renamed-user","name":null,"avatar_url":null}"#
        } else if path == "/user/installations" {
            json = #"{"total_count":0,"installations":[]}"#
        } else {
            json = #"{"message":"unexpected request"}"#
        }
        let response = try #require(
            HTTPURLResponse(
                url: request.url!,
                statusCode:
                    path == "/user" || path == "/user/installations"
                        ? 200
                        : 500,
                httpVersion: "HTTP/1.1",
                headerFields: nil
            )
        )
        return (Data(json.utf8), response)
    }
}

private struct EnablePersistenceWorkflowLoader: GitHubWorkflowRunLoading {
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
func enablingPersistsBeforeStartingSessionRefresh() async throws {
    let events = EnablePersistenceEvents()
    let profile = try enablePersistenceProfile(isEnabled: false)
    let profileStore = EnablePersistenceProfileStore(
        profile,
        events: events
    )
    let credentialStore = EnablePersistenceCredentialStore(
        key: profile.credentialKey,
        credential: GitHubCredential(
            accessToken: "enable-access",
            endpointIdentity: "https://github.com"
        ),
        events: events
    )
    let transport = EnablePersistenceTransport()
    let coordinator = GitHubConnectionSessionCoordinator(
        credentialStore: credentialStore,
        accessClient: GitHubAccessClient(transport: transport)
    )
    let model = GitHubConnectionsRuntimeModel(
        profileStore: profileStore,
        sessionCoordinator: coordinator,
        activityProvider: GitHubActivityProvider(
            workflowRunLoader: EnablePersistenceWorkflowLoader()
        )
    )
    model.profiles = [profile]
    model.statusByConnectionID[profile.id] = .disabled

    model.setEnabled(true, profileID: profile.id)

    await profileStore.waitUntilFirstSaveStarts()
    #expect(
        !(await events.snapshot()).contains("credential-load")
    )

    await profileStore.releaseFirstSave()
    try await waitForEnableRefresh(model, profileID: profile.id)

    let recorded = await events.snapshot()
    let firstSaveEnd = try #require(
        recorded.firstIndex(of: "profile-save-end")
    )
    let credentialLoad = try #require(
        recorded.firstIndex(of: "credential-load")
    )
    #expect(firstSaveEnd < credentialLoad)

    let current = try #require(
        model.profiles.first(where: { $0.id == profile.id })
    )
    #expect(current.isEnabled)
    #expect(current.account.login == "renamed-user")

    let stored = try #require(
        await profileStore.value(for: profile.id)
    )
    #expect(stored == current)
}

@Test @MainActor
func failedDisablePersistenceRollsBackOptimisticProfileAndStatus() async throws {
    let profile = try enablePersistenceProfile(isEnabled: true)
    let profileStore = FailingEnableProfileStore(profile)
    let credentialStore = EnablePersistenceCredentialStore(
        key: profile.credentialKey,
        credential: GitHubCredential(
            accessToken: "enable-access",
            endpointIdentity: "https://github.com"
        )
    )
    let model = GitHubConnectionsRuntimeModel(
        profileStore: profileStore,
        sessionCoordinator: GitHubConnectionSessionCoordinator(
            credentialStore: credentialStore
        ),
        activityProvider: GitHubActivityProvider(
            workflowRunLoader: EnablePersistenceWorkflowLoader()
        )
    )
    let previousStatus =
        GitHubConnectionPresentationStatus.connected(
            repositoryCount: 3
        )
    model.profiles = [profile]
    model.statusByConnectionID[profile.id] = previousStatus

    model.setEnabled(false, profileID: profile.id)

    for _ in 0 ..< 1_000 {
        if model.statusByConnectionID[profile.id] == previousStatus,
           model.profiles.first(where: { $0.id == profile.id })
                == profile
        {
            break
        }
        await Task.yield()
    }

    #expect(
        model.profiles.first(where: { $0.id == profile.id })
            == profile
    )
    #expect(model.statusByConnectionID[profile.id] == previousStatus)
}

private func enablePersistenceProfile(
    isEnabled: Bool
) throws -> GitHubConnectionProfile {
    GitHubConnectionProfile(
        connection: GitHubConnection(
            id: UUID(
                uuidString:
                    "78000000-0000-0000-0000-000000000001"
            )!,
            displayName: "GitHub.com",
            deploymentKind: .githubDotCom,
            webBaseURL: try #require(
                URL(string: "https://github.com")
            )
        ),
        account: GitHubAccountIdentity(
            id: "42",
            login: "old-user"
        ),
        authenticationMethod: .deviceFlow,
        clientID: "test-client-id",
        isEnabled: isEnabled,
        createdAt: Date(timeIntervalSince1970: 1_000),
        lastConnectedAt: Date(timeIntervalSince1970: 2_000)
    )
}

@MainActor
private func waitForEnableRefresh(
    _ model: GitHubConnectionsRuntimeModel,
    profileID: UUID
) async throws {
    for _ in 0 ..< 2_000 {
        if case .connected = model.statusByConnectionID[profileID] {
            return
        }
        await Task.yield()
    }
    Issue.record("Timed out waiting for enabled connection refresh")
}

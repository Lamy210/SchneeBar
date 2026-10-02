@testable import SchneeBar
import Foundation
import SchneeBarGitHub
import SchneeBarGitHubActivityProvider
import Testing

private actor TogglePersistenceGate {
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

private actor TogglePersistenceProfileStore: GitHubConnectionProfileStore {
    private var values: [UUID: GitHubConnectionProfile]
    private var shouldBlockNextSave = true
    private let saveStarted = TogglePersistenceGate()
    private let saveRelease = TogglePersistenceGate()
    private let blockedSaveCompleted = TogglePersistenceGate()

    init(_ profile: GitHubConnectionProfile) {
        values = [profile.id: profile]
    }

    func loadAll() async throws -> [GitHubConnectionProfile] {
        Array(values.values)
    }

    func load(id: UUID) async throws -> GitHubConnectionProfile? {
        values[id]
    }

    func save(_ profile: GitHubConnectionProfile) async throws {
        let isBlockedSave = shouldBlockNextSave
        if isBlockedSave {
            shouldBlockNextSave = false
            await saveStarted.open()
            await saveRelease.wait()
        }
        values[profile.id] = profile
        if isBlockedSave {
            await blockedSaveCompleted.open()
        }
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
}

private actor TogglePersistenceCredentialStore: GitHubCredentialStore {
    private var values: [GitHubCredentialKey: GitHubCredential]

    init(
        key: GitHubCredentialKey,
        credential: GitHubCredential
    ) {
        values = [key: credential]
    }

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
}

private struct TogglePersistenceWorkflowLoader: GitHubWorkflowRunLoading {
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
func delayedToggleSaveCannotResurrectDisconnectedProfile() async throws {
    let profile = try togglePersistenceProfile()
    let profileStore = TogglePersistenceProfileStore(profile)
    let credentialStore = TogglePersistenceCredentialStore(
        key: profile.credentialKey,
        credential: GitHubCredential(
            accessToken: "toggle-access",
            endpointIdentity: "https://github.com"
        )
    )
    let coordinator = GitHubConnectionSessionCoordinator(
        credentialStore: credentialStore
    )
    let model = GitHubConnectionsRuntimeModel(
        profileStore: profileStore,
        sessionCoordinator: coordinator,
        activityProvider: GitHubActivityProvider(
            workflowRunLoader: TogglePersistenceWorkflowLoader()
        )
    )
    model.profiles = [profile]
    model.statusByConnectionID[profile.id] = .connected(
        repositoryCount: 0
    )

    model.setEnabled(false, profileID: profile.id)
    await profileStore.waitUntilSaveStarts()

    await model.disconnect(profileID: profile.id)

    #expect(model.profiles.isEmpty)
    #expect(try await profileStore.load(id: profile.id) == nil)

    await profileStore.releaseSave()
    await profileStore.waitUntilBlockedSaveCompletes()
    await waitForTogglePersistenceRepair(
        profileStore,
        profileID: profile.id
    )

    #expect(model.profiles.isEmpty)
    #expect(try await profileStore.load(id: profile.id) == nil)
}

@Test @MainActor
func delayedToggleSaveCannotOverwriteNewerRepositorySelection() async throws {
    let profile = try togglePersistenceProfile()
    let profileStore = TogglePersistenceProfileStore(profile)
    let credentialStore = TogglePersistenceCredentialStore(
        key: profile.credentialKey,
        credential: GitHubCredential(
            accessToken: "toggle-access",
            endpointIdentity: "https://github.com"
        )
    )
    let model = GitHubConnectionsRuntimeModel(
        profileStore: profileStore,
        sessionCoordinator: GitHubConnectionSessionCoordinator(
            credentialStore: credentialStore
        ),
        activityProvider: GitHubActivityProvider(
            workflowRunLoader: TogglePersistenceWorkflowLoader()
        )
    )
    model.profiles = [profile]

    model.setEnabled(false, profileID: profile.id)
    await profileStore.waitUntilSaveStarts()

    let selectionSaved = await model.saveRepositorySelection(
        profileID: profile.id,
        mode: .selected,
        selectedRepositoryIDs: [202, 303]
    )
    #expect(selectionSaved)

    await profileStore.releaseSave()
    await profileStore.waitUntilBlockedSaveCompletes()
    await waitForToggleSelectionRepair(
        profileStore,
        profileID: profile.id
    )

    let current = try #require(
        model.profiles.first(where: { $0.id == profile.id })
    )
    #expect(current.isEnabled == false)
    #expect(
        current.repositorySelection
            == .selected([202, 303])
    )

    let stored = try #require(
        try await profileStore.load(id: profile.id)
    )
    #expect(stored == current)
}

private func togglePersistenceProfile() throws -> GitHubConnectionProfile {
    GitHubConnectionProfile(
        connection: GitHubConnection(
            id: UUID(
                uuidString:
                    "34000000-0000-0000-0000-000000000001"
            )!,
            displayName: "GitHub.com",
            deploymentKind: .githubDotCom,
            webBaseURL: try #require(
                URL(string: "https://github.com")
            )
        ),
        account: GitHubAccountIdentity(
            id: "42",
            login: "octocat"
        ),
        authenticationMethod: .deviceFlow,
        clientID: "test-client-id",
        repositorySelection: .selected([101]),
        isEnabled: true,
        createdAt: Date(timeIntervalSince1970: 1_000),
        lastConnectedAt: Date(timeIntervalSince1970: 2_000)
    )
}

private func waitForTogglePersistenceRepair(
    _ store: TogglePersistenceProfileStore,
    profileID: UUID
) async {
    for _ in 0 ..< 1_000 {
        let stored = try? await store.load(id: profileID)
        if stored == nil {
            return
        }
        await Task.yield()
    }
    Issue.record(
        "Timed out waiting for stale toggle persistence repair"
    )
}


private func waitForToggleSelectionRepair(
    _ store: TogglePersistenceProfileStore,
    profileID: UUID
) async {
    for _ in 0 ..< 1_000 {
        if let profile = try? await store.load(id: profileID),
           profile.repositorySelection == .selected([202, 303]),
           profile.isEnabled == false
        {
            return
        }
        await Task.yield()
    }
    Issue.record(
        "Timed out waiting for stale toggle selection repair"
    )
}

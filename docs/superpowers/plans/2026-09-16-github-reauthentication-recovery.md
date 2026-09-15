# GitHub Reauthentication Recovery Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a safe, user-facing GitHub `Re-authenticate` flow that repairs an existing connection without changing its account binding, repository selection, monitoring state, or connection identity.

**Architecture:** `SchneeBarGitHub` owns the recovery transaction: validate the fresh Device Flow credential, require the existing account identity, fetch inventory, recompute capabilities, drain any older refresh task, then atomically replace the Keychain credential. `GitHubConnectionsRuntimeModel` owns the UI transaction and stale-result generation, while `SchneeBarGitHubFeature` renders a dedicated non-editable recovery sheet and an explicit `Re-authenticate` action for `.authenticationRequired` connections.

**Tech Stack:** Swift 6.3, Swift Testing, Swift Concurrency/actors, SwiftUI, Observation, Tuist 4.203.1, Xcode 26.6, macOS 15+, GitHub Actions CI/Visual Regression/CodeQL.

**Spec:** `docs/superpowers/specs/2026-09-16-github-reauthentication-recovery-design.md`

## Global Constraints

- macOS deployment target remains 15.0.
- Xcode 26.6 / Swift 6.3 remain the production baseline; Xcode 27 / Swift 6.4 remain canary-only.
- Tuist stays pinned to 4.203.1 via mise.
- Keep GitHub provider/session behavior in `SchneeBarGitHub`; SwiftUI/AppKit must not leak into that module.
- Recovery must never change the stable GitHub account ID bound to an existing connection.
- Recovery always uses the endpoint and client ID already stored on the selected profile.
- Credential keys remain `(connectionID, accountID)` and recovery of one account must not mutate another account on the same endpoint.
- No credential-store mutation may occur until account identity, repository inventory, capability evaluation, and cancellation checks succeed.
- Before recovery saves a credential, any older refresh task for the same credential key must be cancelled and drained so it cannot write an older rotated credential afterward.
- Failed or cancelled recovery must not disconnect, delete, or silently replace the existing profile.
- Repository selection, enabled state, connection UUID, creation time, authentication method, endpoint, display configuration, and client ID remain unchanged by successful recovery.
- Bearer tokens and refresh tokens must not enter UI models, error strings, fixtures, logs, docs, or committed test data that resembles real credentials.
- Do not add generic cross-provider authentication abstractions in this change.
- SSO/SAML recovery remains out of scope; `.ssoRequired` is unchanged.

## File Structure

- `Sources/SchneeBarGitHub/GitHubConnectionSessionCoordinator.swift` — recovery transaction, credential replacement ordering, refresh-task draining.
- `Tests/SchneeBarGitHubTests/GitHubConnectionSessionCoordinatorTests.swift` — provider/session RED/GREEN contract and race tests.
- `Sources/SchneeBarGitHubFeature/GitHubConnectionRecoveryView.swift` — dedicated recovery presentation and phases.
- `Sources/SchneeBarGitHubFeature/GitHubConnectionsView.swift` — choose `Re-authenticate` vs `Refresh` from normalized presentation status.
- `Sources/SchneeBarApp/GitHubConnectionsRuntimeModel.swift` — recovery orchestration, profile/cache update, auth-operation exclusivity, stale-result generations.
- `Sources/SchneeBarApp/SettingsView.swift` — recovery sheet wiring.
- `Project.swift` — add `SchneeBarAppTests` so runtime orchestration is directly testable.
- `Tests/SchneeBarAppTests/GitHubConnectionsRuntimeModelRecoveryTests.swift` — runtime state, preservation, cancellation, multi-account, and stale-refresh tests.
- `Sources/SchneeBarPreviewSupport/GitHubConnectionFixtures.swift` — deterministic authentication-required and recovery fixtures.
- `Sources/SchneeBarVisualHarness/**` and/or `Sources/SchneeBarVisualSnapshotCLI/**` — register recovery visual states using existing harness conventions.
- `docs/DEVELOPMENT_PLAN.md` — mark Phase 2 credential recovery/reauthentication UX complete after implementation passes verification.

## Execution Prerequisite

Merge the approved design/plan documentation into `main`, then create `feat/github-reauthentication-recovery` from that exact `main`. Production code must not be implemented on the documentation branch.

```bash
# Conceptual repository workflow:
# 1. Open and merge the docs PR from docs/github-reauthentication-recovery-design.
# 2. Create feat/github-reauthentication-recovery from the resulting main SHA.
# 3. Execute Tasks 1-5 in order.
```

---

### Task 1: Add the race-safe session recovery transaction

**Files:**
- Modify: `Sources/SchneeBarGitHub/GitHubConnectionSessionCoordinator.swift`
- Modify: `Tests/SchneeBarGitHubTests/GitHubConnectionSessionCoordinatorTests.swift`

**Interfaces:**
- Consumes: existing `GitHubConnection`, `GitHubAccountIdentity`, `GitHubCredential`, `GitHubCredentialStore`, `GitHubAccessClient`, `GitHubCapabilityEvaluator`, `refreshTasks`.
- Produces:

```swift
public func recover(
    connection: GitHubConnection,
    expectedIdentity: GitHubAccountIdentity,
    credential: GitHubCredential
) async throws -> GitHubConnectionSession
```

- Internal helper:

```swift
private func cancelAndDrainRefreshTask(for key: GitHubCredentialKey) async
```

- [ ] **Step 1: Write RED tests for validation-before-persistence and account binding**

Extend `GitHubConnectionSessionCoordinatorTests.swift` with deterministic tests that seed an old credential before recovery and assert the old value survives all validation failures.

```swift
@Test
func recoverMatchingAccountValidatesBeforeReplacingCredential() async throws {
    let transport = SessionQueueTransport([
        SessionStubResponse(userJSON(id: 42, login: "octocat-renamed")),
        SessionStubResponse(userJSON(id: 42, login: "octocat-renamed")),
        SessionStubResponse(#"{\"total_count\":0,\"installations\":[]}"#),
    ])
    let store = MemoryGitHubCredentialStore()
    let connection = try sessionConnection()
    let expected = GitHubAccountIdentity(id: "42", login: "octocat")
    let key = GitHubCredentialKey(connectionID: connection.id, accountID: expected.id)
    let old = GitHubCredential(accessToken: "old-token")
    let fresh = GitHubCredential(accessToken: "fresh-token")
    try await store.save(old, for: key)
    let baselineSaves = await store.saves()
    let coordinator = makeCoordinator(transport: transport, store: store)

    let session = try await coordinator.recover(
        connection: connection,
        expectedIdentity: expected,
        credential: fresh
    )

    #expect(session.connectionID == connection.id)
    #expect(session.account.identity.id == expected.id)
    #expect(session.account.identity.login == "octocat-renamed")
    #expect(session.credentialKey == key)
    #expect(await store.credential(for: key) == fresh)
    #expect(await store.saves() == baselineSaves + 1)
}

@Test
func recoverRejectsDifferentAccountWithoutMutatingCredentialStore() async throws {
    let transport = SessionQueueTransport([
        SessionStubResponse(userJSON(id: 99, login: "other-user")),
    ])
    let store = MemoryGitHubCredentialStore()
    let connection = try sessionConnection()
    let expected = GitHubAccountIdentity(id: "42", login: "octocat")
    let key = GitHubCredentialKey(connectionID: connection.id, accountID: expected.id)
    let old = GitHubCredential(accessToken: "old-token")
    try await store.save(old, for: key)
    let baselineSaves = await store.saves()
    let coordinator = makeCoordinator(transport: transport, store: store)

    await #expect(
        throws: GitHubConnectionSessionError.accountMismatch(
            expectedID: "42",
            actualID: "99"
        )
    ) {
        try await coordinator.recover(
            connection: connection,
            expectedIdentity: expected,
            credential: GitHubCredential(accessToken: "wrong-account-token")
        )
    }

    #expect(await store.credential(for: key) == old)
    #expect(await store.saves() == baselineSaves)
    #expect(await store.deletes() == 0)
}
```

Add the remaining RED cases with these exact assertions:

```swift
// account lookup 401
await #expect(throws: GitHubConnectionSessionError.reauthenticationRequired) { ... }
#expect(await store.credential(for: key) == old)
#expect(await store.saves() == baselineSaves)

// inventory 401 after successful identity lookup
await #expect(throws: GitHubConnectionSessionError.reauthenticationRequired) { ... }
#expect(await store.credential(for: key) == old)
#expect(await store.saves() == baselineSaves)

// transport/network error during inventory
await #expect(throws: URLError.self) { ... }
#expect(await store.credential(for: key) == old)
#expect(await store.saves() == baselineSaves)

// same endpoint, second account B has a different key
#expect(await store.credential(for: accountAKey) == recoveredA)
#expect(await store.credential(for: accountBKey) == accountBOld)
```

- [ ] **Step 2: Run the GitHub test suite and verify RED**

```bash
mise exec -- tuist test -- -skipMacroValidation CODE_SIGNING_ALLOWED=NO
```

Expected: compile/test failure because `GitHubConnectionSessionCoordinator.recover` does not exist.

- [ ] **Step 3: Implement minimal `recover` with validate-first/persist-second ordering**

Add the public actor method with this order:

```swift
public func recover(
    connection: GitHubConnection,
    expectedIdentity: GitHubAccountIdentity,
    credential: GitHubCredential
) async throws -> GitHubConnectionSession {
    let account: GitHubAuthenticatedAccount
    do {
        account = try await accessClient.authenticatedAccount(
            connection: connection,
            credential: credential
        )
    } catch GitHubAccessClientError.httpStatus(401) {
        throw GitHubConnectionSessionError.reauthenticationRequired
    }

    guard account.identity.id == expectedIdentity.id else {
        throw GitHubConnectionSessionError.accountMismatch(
            expectedID: expectedIdentity.id,
            actualID: account.identity.id
        )
    }

    let inventory: GitHubAccessInventory
    do {
        inventory = try await accessClient.inventory(
            connection: connection,
            credential: credential
        )
    } catch GitHubAccessClientError.httpStatus(401) {
        throw GitHubConnectionSessionError.reauthenticationRequired
    }

    let capabilities = capabilityEvaluator.evaluate(
        connection: connection,
        inventory: inventory
    )
    let key = credentialKey(connection: connection, identity: expectedIdentity)

    try Task.checkCancellation()
    await cancelAndDrainRefreshTask(for: key)
    try Task.checkCancellation()
    try await credentialStore.save(credential, for: key)

    return GitHubConnectionSession(
        connectionID: connection.id,
        account: account,
        credentialKey: key,
        inventory: inventory,
        capabilities: capabilities
    )
}
```

Implement task draining so an older refresh cannot save after recovery:

```swift
private func cancelAndDrainRefreshTask(for key: GitHubCredentialKey) async {
    guard let task = refreshTasks.removeValue(forKey: key) else {
        return
    }
    task.cancel()
    _ = try? await task.value
}
```

Do not add rollback deletion. Recovery performs exactly one credential save after validation.

- [ ] **Step 4: Add RED/GREEN coverage for the refresh-task race and cancellation-before-save**

Create a controllable refresh transport/store gate so an existing `restore(...)` starts token refresh and is suspended before its save. Start recovery for the same key, release the old refresh, and assert the final stored credential is the recovery credential.

The test must end with:

```swift
#expect(await store.credential(for: key) == recoveryCredential)
```

Add a cancellation test where recovery is cancelled after remote validation is released but before the final store write. Use a credential-store save gate and assert that cancellation prevents the replacement save:

```swift
#expect(await store.credential(for: key) == oldCredential)
```

- [ ] **Step 5: Run tests to GREEN and commit**

```bash
mise exec -- tuist test -- -skipMacroValidation CODE_SIGNING_ALLOWED=NO
git add Sources/SchneeBarGitHub/GitHubConnectionSessionCoordinator.swift \
  Tests/SchneeBarGitHubTests/GitHubConnectionSessionCoordinatorTests.swift
git commit -m "feat: add safe GitHub credential recovery"
```

---

### Task 2: Add dedicated recovery presentation and row action

**Files:**
- Create: `Sources/SchneeBarGitHubFeature/GitHubConnectionRecoveryView.swift`
- Modify: `Sources/SchneeBarGitHubFeature/GitHubConnectionsView.swift`
- Modify: `Sources/SchneeBarPreviewSupport/GitHubConnectionFixtures.swift`

**Interfaces:**
- Consumes: `GitHubDeviceAuthorizationPresentation`, `GitHubConnectionCardModel`, `GitHubConnectionPresentationStatus`.
- Produces:

```swift
public enum GitHubConnectionRecoveryPhase: Equatable, Sendable {
    case requestingCode
    case waitingForAuthorization(GitHubDeviceAuthorizationPresentation)
    case finalizing
    case failed(message: String)
}

public struct GitHubConnectionRecoveryContext: Equatable, Sendable {
    public let connectionID: UUID
    public let displayName: String
    public let host: String
    public let accountLogin: String
}
```

`GitHubConnectionsView` initializer adds:

```swift
onReauthenticate: @escaping (UUID) -> Void
```

- [ ] **Step 1: Add the presentation types and dedicated recovery view**

Create `GitHubConnectionRecoveryView.swift`. The view must not expose editable endpoint/account/client-ID fields. Its initializer is:

```swift
public init(
    context: GitHubConnectionRecoveryContext,
    phase: GitHubConnectionRecoveryPhase,
    onRetry: @escaping () -> Void,
    onOpenVerificationPage: @escaping (URL) -> Void,
    onCancel: @escaping () -> Void
)
```

The header identifies the immutable target:

```swift
Text("Re-authenticate GitHub")
    .font(.title2.bold())
Text("\(context.displayName) · @\(context.accountLogin)")
    .font(.headline)
Text(context.host)
    .font(.caption.monospaced())
    .foregroundStyle(.secondary)
```

State rendering is exact:

```swift
switch phase {
case .requestingCode:
    progress("Requesting a GitHub authorization code…")
case let .waitingForAuthorization(presentation):
    authorizationCode(presentation)
case .finalizing:
    progress("Validating account and repository access…")
case let .failed(message):
    Label(message, systemImage: "exclamationmark.triangle.fill")
        .foregroundStyle(.red)
    Button("Try Again", action: onRetry)
}
```

The waiting state reuses the same one-time code copy and `Open GitHub Authorization Page` interaction as onboarding. Keep Cancel available throughout; runtime decides whether dismissal is interactive while active.

- [ ] **Step 2: Change the connection-row action without changing other statuses**

Extend `GitHubConnectionsView` with `onReauthenticate`. In the action row:

```swift
if case .authenticationRequired = connection.status {
    Button("Re-authenticate") {
        onReauthenticate(connection.id)
    }
    .buttonStyle(.borderless)
} else {
    Button("Refresh") {
        onRefresh(connection.id)
    }
    .buttonStyle(.borderless)
    .disabled(!connection.isEnabled)
}
```

`Manage` remains present in both branches. Do not disable `Re-authenticate` because monitoring is disabled; a disabled connection may still be repaired.

- [ ] **Step 3: Add deterministic fixtures**

In `GitHubConnectionsFixture.needsAttention`, retain the existing authentication-required connection and make it the visual proof that `Re-authenticate` appears even when `isEnabled == false`.

Add recovery fixture constants using non-real values:

```swift
public enum GitHubConnectionRecoveryFixture {
    public static let context = GitHubConnectionRecoveryContext(
        connectionID: UUID(uuidString: "22000000-0000-0000-0000-000000000001")!,
        displayName: "Personal GitHub",
        host: "github.com",
        accountLogin: "snow-user"
    )

    public static let authorization = GitHubDeviceAuthorizationPresentation(
        userCode: "ABCD-EFGH",
        verificationURI: URL(string: "https://github.com/login/device")!,
        expiresAt: Date(timeIntervalSince1970: 2_000_000_000)
    )
}
```

- [ ] **Step 4: Build before runtime wiring and commit**

```bash
mise exec -- tuist generate
mise exec -- tuist build -- -skipMacroValidation CODE_SIGNING_ALLOWED=NO
git add Sources/SchneeBarGitHubFeature/GitHubConnectionRecoveryView.swift \
  Sources/SchneeBarGitHubFeature/GitHubConnectionsView.swift \
  Sources/SchneeBarPreviewSupport/GitHubConnectionFixtures.swift
git commit -m "feat: add GitHub reauthentication presentation"
```

---

### Task 3: Add directly testable runtime recovery orchestration

**Files:**
- Modify: `Project.swift`
- Modify: `Sources/SchneeBarApp/GitHubConnectionsRuntimeModel.swift`
- Create: `Tests/SchneeBarAppTests/GitHubConnectionsRuntimeModelRecoveryTests.swift`

**Interfaces:**
- Consumes: `GitHubConnectionSessionCoordinator.recover(...)`, `GitHubDeviceFlowClient.begin(...)`, `GitHubDeviceAuthorizationWaiter.waitForAuthorization(...)`, profile store, Activity provider.
- Produces runtime state/actions:

```swift
var recoveringConnectionID: UUID?
var recoveryPhase: GitHubConnectionRecoveryPhase
var recoveryContext: GitHubConnectionRecoveryContext?
var recoveryIsActive: Bool

func beginRecovery(profileID: UUID)
func retryRecovery()
func cancelRecovery()
```

- Internal stale-result mechanism:

```swift
private var operationGenerationByConnectionID: [UUID: UInt64] = [:]
private func advanceOperationGeneration(for connectionID: UUID) -> UInt64
private func isCurrentOperationGeneration(_ generation: UInt64, for connectionID: UUID) -> Bool
```

- [ ] **Step 1: Add `SchneeBarAppTests` to Tuist**

Add a unit-test target after the existing test targets:

```swift
.target(
    name: "SchneeBarAppTests",
    destinations: .macOS,
    product: .unitTests,
    bundleId: "dev.lamy.schneebar.app-tests",
    deploymentTargets: deploymentTarget,
    sources: ["Tests/SchneeBarAppTests/**"],
    dependencies: [
        .target(name: "SchneeBar"),
        .target(name: "SchneeBarCore"),
        .target(name: "SchneeBarGitHub"),
        .target(name: "SchneeBarGitHubProfiles"),
        .target(name: "SchneeBarGitHubFeature"),
        .target(name: "SchneeBarGitHubActivityProvider"),
    ]
)
```

Run generation immediately:

```bash
mise exec -- tuist generate
```

Expected: generated project includes `SchneeBarAppTests`.

- [ ] **Step 2: Write RED runtime tests before adding recovery methods**

Create `GitHubConnectionsRuntimeModelRecoveryTests.swift` using `@testable import SchneeBar` and actor-based in-memory doubles. At minimum implement these tests with fixed UUIDs/dates:

```swift
@Test @MainActor
func successfulRecoveryPreservesProfileConfiguration() async throws {
    let fixture = try RuntimeRecoveryFixture.make()
    let original = fixture.profile
    fixture.model.profiles = [original]
    fixture.model.statusByConnectionID[original.id] = .authenticationRequired

    fixture.model.beginRecovery(profileID: original.id)
    await fixture.completeAuthorizationAsExpectedAccount(login: "renamed-user")
    await fixture.waitUntilRecoveryFinishes()

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
}

@Test @MainActor
func wrongAccountRecoveryDoesNotCreateOrReplaceProfile() async throws {
    let fixture = try RuntimeRecoveryFixture.make()
    let original = fixture.profile
    fixture.model.profiles = [original]
    fixture.model.statusByConnectionID[original.id] = .authenticationRequired

    fixture.model.beginRecovery(profileID: original.id)
    await fixture.completeAuthorizationAsAccount(id: "99", login: "other-user")
    await fixture.waitUntilRecoveryFails()

    #expect(fixture.model.profiles == [original])
    #expect(fixture.model.statusByConnectionID[original.id] == .authenticationRequired)
    #expect(fixture.model.recoveringConnectionID == original.id)
}
```

Also implement exact behavior checks for:

```swift
@Test @MainActor func recoveryWorksWhileMonitoringIsDisabled() async throws
@Test @MainActor func recoveryMissingClientIDFailsWithoutDeletingProfile() async throws
@Test @MainActor func cancellingRecoveryLeavesProfileAndStatusUnchanged() async throws
@Test @MainActor func recoveringAccountADoesNotChangeAccountBOnSameEndpoint() async throws
@Test @MainActor func beginOnboardingCancelsOrRejectsActiveRecovery() async throws
@Test @MainActor func beginRecoveryCancelsOrRejectsActiveOnboarding() async throws
@Test @MainActor func staleRefreshCannotOverwriteSuccessfulRecovery() async throws
```

For missing client ID, assert the phase is:

```swift
.failed(message: "This saved GitHub connection is missing the client ID required for re-authentication. Add the connection again to repair it.")
```

- [ ] **Step 3: Run tests and verify RED**

```bash
mise exec -- tuist test -- -skipMacroValidation CODE_SIGNING_ALLOWED=NO
```

Expected: `SchneeBarAppTests` compiles far enough to report missing recovery state/methods, or fails at those references.

- [ ] **Step 4: Implement recovery state and authentication-operation exclusivity**

Add runtime state:

```swift
var recoveringConnectionID: UUID?
var recoveryPhase: GitHubConnectionRecoveryPhase = .requestingCode

@ObservationIgnored
private var recoveryTask: Task<Void, Never>?

@ObservationIgnored
private var operationGenerationByConnectionID: [UUID: UInt64] = [:]
```

Expose context from the currently bound profile:

```swift
var recoveryContext: GitHubConnectionRecoveryContext? {
    guard let id = recoveringConnectionID,
          let profile = profiles.first(where: { $0.id == id }) else {
        return nil
    }
    return GitHubConnectionRecoveryContext(
        connectionID: profile.id,
        displayName: profile.connection.displayName,
        host: displayHost(for: profile.connection),
        accountLogin: profile.account.login
    )
}
```

Use a single invariant for auth transactions: beginning onboarding cancels recovery; beginning recovery cancels onboarding before starting. Do not allow both tasks to remain live.

Implement:

```swift
func beginRecovery(profileID: UUID) {
    cancelOnboarding()
    startRecovery(profileID: profileID)
}

func retryRecovery() {
    guard let profileID = recoveringConnectionID else { return }
    startRecovery(profileID: profileID)
}

func cancelRecovery() {
    recoveryTask?.cancel()
    recoveryTask = nil
    recoveringConnectionID = nil
    recoveryPhase = .requestingCode
}
```

Keep `recoveringConnectionID` bound on `.failed` so Retry has a deterministic target.

- [ ] **Step 5: Implement the Device Flow recovery transaction and profile update**

`startRecovery(profileID:)` must snapshot the profile binding at start and require non-empty `clientID`.

Use this sequence inside the Task:

```swift
let generation = advanceOperationGeneration(for: profile.id)
recoveryPhase = .requestingCode
let authorization = try await deviceFlowClient.begin(
    connection: profile.connection,
    clientID: clientID
)
recoveryPhase = .waitingForAuthorization(
    GitHubDeviceAuthorizationPresentation(
        userCode: authorization.userCode,
        verificationURI: authorization.verificationURI,
        expiresAt: authorization.expiresAt
    )
)
let credential = try await authorizationWaiter.waitForAuthorization(
    connection: profile.connection,
    clientID: clientID,
    session: authorization
)
try Task.checkCancellation()
recoveryPhase = .finalizing
let session = try await sessionCoordinator.recover(
    connection: profile.connection,
    expectedIdentity: profile.account,
    credential: credential
)
try Task.checkCancellation()
```

Before applying success, verify all of:

```swift
guard isCurrentOperationGeneration(generation, for: profile.id),
      let current = profiles.first(where: { $0.id == profile.id }),
      current.account.id == profile.account.id,
      current.connection.id == profile.connection.id
else {
    return
}
```

Build the updated profile with preserved configuration and refreshed account metadata/connection timestamp:

```swift
let updated = GitHubConnectionProfile(
    connection: current.connection,
    account: session.account.identity,
    authenticationMethod: current.authenticationMethod,
    clientID: current.clientID,
    repositorySelection: current.repositorySelection,
    isEnabled: current.isEnabled,
    createdAt: current.createdAt,
    lastConnectedAt: .now
)
```

After profile-store save succeeds:

```swift
await activityProvider.reset(connectionID: updated.id)
upsert(updated)
inventoryByConnectionID[updated.id] = session.inventory
capabilitiesByConnectionID[updated.id] = session.capabilities
statusByConnectionID[updated.id] = updated.isEnabled
    ? presentationStatus(for: session.inventory)
    : .disabled
onActivitySourceChanged?()
recoveryTask = nil
recoveringConnectionID = nil
recoveryPhase = .requestingCode
```

If profile persistence fails after the credential was saved, keep the credential, keep the durable old profile, set immediate status `.unavailable`, and show a failed recovery phase. Do not call `disconnect`.

Wrong-account errors must map to a user-facing message that mentions the expected login, not numeric IDs:

```swift
"GitHub authorized a different account. Sign in as @\(profile.account.login) and try again."
```

- [ ] **Step 6: Guard normal refresh results with the same per-connection generation**

At the beginning of `refresh(profileID:)`, capture:

```swift
let generation = advanceOperationGeneration(for: profileID)
```

Before every cache/status/profile application from that refresh, require:

```swift
guard isCurrentOperationGeneration(generation, for: profileID) else {
    return
}
```

Starting recovery advances the same generation, making all older refresh results stale. Do not globally serialize unrelated connections.

- [ ] **Step 7: Run all tests to GREEN and commit**

```bash
mise exec -- tuist generate
mise exec -- tuist test -- -skipMacroValidation CODE_SIGNING_ALLOWED=NO
git add Project.swift \
  Sources/SchneeBarApp/GitHubConnectionsRuntimeModel.swift \
  Tests/SchneeBarAppTests/GitHubConnectionsRuntimeModelRecoveryTests.swift
git commit -m "feat: orchestrate GitHub connection recovery"
```

---

### Task 4: Wire recovery into Settings and deterministic visual regression

**Files:**
- Modify: `Sources/SchneeBarApp/SettingsView.swift`
- Modify: `Sources/SchneeBarPreviewSupport/GitHubConnectionFixtures.swift`
- Modify the existing GitHub visual-harness registration file under `Sources/SchneeBarVisualHarness/` discovered by searching for `GitHubConnectionsFixture`.
- Modify the existing snapshot registration under `Sources/SchneeBarVisualSnapshotCLI/` if the harness and CLI use separate registration tables.

**Interfaces:**
- Consumes: `beginRecovery(profileID:)`, `retryRecovery()`, `cancelRecovery()`, `recoveryContext`, `recoveryPhase`, `GitHubConnectionRecoveryView`.
- Produces no new domain interfaces.

- [ ] **Step 1: Wire the row action and recovery sheet**

Pass the new callback:

```swift
GitHubConnectionsView(
    connections: githubModel.connectionCards,
    onAdd: { githubModel.beginOnboarding(defaultClientID: bundledGitHubClientID) },
    onRefresh: { id in
        Task { @MainActor in
            await githubModel.refresh(profileID: id)
        }
    },
    onReauthenticate: { id in
        githubModel.beginRecovery(profileID: id)
    },
    onManage: presentManagement,
    onSetEnabled: { id, isEnabled in
        githubModel.setEnabled(isEnabled, profileID: id)
    }
)
```

Add a recovery sheet using a `Binding<Bool>` derived from `recoveringConnectionID != nil`. Render unavailable context as `ContentUnavailableView` rather than fabricating account/host data.

```swift
.sheet(isPresented: recoveryIsPresented) {
    if let context = githubModel.recoveryContext {
        GitHubConnectionRecoveryView(
            context: context,
            phase: githubModel.recoveryPhase,
            onRetry: { githubModel.retryRecovery() },
            onOpenVerificationPage: { openURL($0) },
            onCancel: { githubModel.cancelRecovery() }
        )
        .interactiveDismissDisabled(githubModel.recoveryIsActive)
    } else {
        ContentUnavailableView(
            "Connection unavailable",
            systemImage: "exclamationmark.triangle",
            description: Text("Close this sheet and refresh the GitHub connection list.")
        )
    }
}
```

- [ ] **Step 2: Register visual states**

Add deterministic scenes for:

```swift
GitHubConnectionsFixture.needsAttention
GitHubConnectionRecoveryView(
    context: GitHubConnectionRecoveryFixture.context,
    phase: .waitingForAuthorization(GitHubConnectionRecoveryFixture.authorization),
    onRetry: {},
    onOpenVerificationPage: { _ in },
    onCancel: {}
)
GitHubConnectionRecoveryView(
    context: GitHubConnectionRecoveryFixture.context,
    phase: .failed(
        message: "GitHub authorized a different account. Sign in as @snow-user and try again."
    ),
    onRetry: {},
    onOpenVerificationPage: { _ in },
    onCancel: {}
)
```

If the visual harness snapshots progress states already, also register `.finalizing`; otherwise the two recovery scenes above plus the connection-card scene are sufficient.

- [ ] **Step 3: Generate current snapshots and inspect diff locally**

```bash
mise exec -- tuist run SchneeBarVisualSnapshotCLI -- --output .visual/current
```

Expected visual behavior:
- authentication-required row says `Re-authenticate`, not `Refresh`;
- action is present even when monitoring is disabled;
- recovery sheet shows immutable connection/account context;
- no token/client secret/private host is rendered;
- wrong-account message identifies only expected login.

- [ ] **Step 4: Build/test and commit**

```bash
mise exec -- tuist build -- -skipMacroValidation CODE_SIGNING_ALLOWED=NO
mise exec -- tuist test -- -skipMacroValidation CODE_SIGNING_ALLOWED=NO
git add Sources/SchneeBarApp/SettingsView.swift \
  Sources/SchneeBarPreviewSupport/GitHubConnectionFixtures.swift \
  Sources/SchneeBarVisualHarness \
  Sources/SchneeBarVisualSnapshotCLI
git commit -m "feat: wire GitHub reauthentication recovery UI"
```

---

### Task 5: Synchronize Phase 2 documentation and verify the exact PR head

**Files:**
- Modify: `docs/DEVELOPMENT_PLAN.md`
- No production changes unless verification exposes a defect; any defect fix must get its own RED test before the fix.

**Interfaces:**
- No new interfaces.

- [ ] **Step 1: Update Phase 2 status**

Move credential recovery/reauthentication from remaining Phase 2 work into implemented work. Keep broader enterprise validation as remaining. The Phase 2 remaining list becomes conceptually:

```markdown
Remaining:
- broader GitHub Enterprise validation before Phase 5
- capability presentation for review requests, Checks, and deployments as those surfaces land
```

Add implemented bullets for:

```markdown
- dedicated existing-connection Device Flow reauthentication
- same-account binding enforcement during recovery
- validate-before-Keychain replacement semantics
- refresh/recovery race protection
```

- [ ] **Step 2: Run the complete local verification gate**

```bash
mise install
mise exec -- tuist generate
mise exec -- tuist build -- -skipMacroValidation CODE_SIGNING_ALLOWED=NO
mise exec -- tuist test -- -skipMacroValidation CODE_SIGNING_ALLOWED=NO
mise exec -- tuist run SchneeBarVisualSnapshotCLI -- --output .visual/current
```

Do not report success from partial commands. Record the final test count/output and exact commit SHA for the PR description.

- [ ] **Step 3: Commit documentation**

```bash
git add docs/DEVELOPMENT_PLAN.md
git commit -m "docs: complete GitHub recovery milestone"
```

- [ ] **Step 4: Open a draft PR with RED/GREEN evidence**

Use a title matching the repository's recent style:

```text
feat: add GitHub connection recovery
```

The PR body must explicitly record:

```markdown
## Summary
- adds dedicated reauthentication for existing GitHub connections
- preserves account/connection/repository-selection identity
- validates account + inventory before replacing Keychain credential
- prevents stale token refresh from overwriting recovered credentials

## TDD evidence
- RED: session recovery tests fail before `recover(...)`
- GREEN: matching-account, wrong-account, 401, network, cancellation, multi-account, and refresh-race tests pass
- RED: runtime recovery tests fail before orchestration state/actions exist
- GREEN: profile preservation, cancellation, disabled-monitoring recovery, auth exclusivity, and stale-refresh tests pass

## Verification
- `mise exec -- tuist generate`
- `mise exec -- tuist build -- -skipMacroValidation CODE_SIGNING_ALLOWED=NO`
- `mise exec -- tuist test -- -skipMacroValidation CODE_SIGNING_ALLOWED=NO`
- deterministic visual snapshots generated and reviewed
```

Create it as Draft first so CodeQL remains deferred under the current repository workflow.

- [ ] **Step 5: Verify GitHub Actions on the exact head, then mark Ready**

Before marking Ready, require normal CI and Visual Regression to pass for the exact current PR head. If either fails, fix with a regression test and repeat local verification.

After CI/Visual are green, mark the PR Ready for review so CodeQL runs. Require CodeQL to pass on that same logical final head before merge.

- [ ] **Step 6: Final review checklist**

Confirm all of these are true before merge:

```text
[ ] No recovery path can create a second profile when the wrong account is authorized.
[ ] No failed validation mutates the existing Keychain credential.
[ ] No older refresh task can overwrite the recovered credential.
[ ] Cancellation before final save is non-destructive.
[ ] Disabled monitoring does not prevent explicit reauthentication.
[ ] Profile UUID, selection, enabled state, creation time, endpoint, and client ID survive recovery.
[ ] Two accounts on github.com remain credential-isolated.
[ ] Recovery UI contains no editable endpoint/account/client-ID fields.
[ ] CI passes on exact PR head.
[ ] Visual Regression passes on exact PR head.
[ ] CodeQL passes after Ready-for-review transition.
```

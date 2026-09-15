# GitHub Reauthentication Recovery Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a safe, user-facing GitHub `Re-authenticate` flow that repairs an existing connection without changing its account binding, repository selection, monitoring state, or connection identity.

**Architecture:** `SchneeBarGitHub` owns the recovery transaction: validate a fresh Device Flow credential, require the existing account identity, fetch inventory, recompute capabilities, drain any older refresh task, then replace the Keychain credential. `GitHubConnectionsRuntimeModel` owns the UI transaction and per-connection stale-result generation, while `SchneeBarGitHubFeature` renders a dedicated non-editable recovery sheet and an explicit `Re-authenticate` action for `.authenticationRequired` connections.

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
- Bearer tokens and refresh tokens must not enter UI models, error strings, fixtures, logs, docs, or committed data that resembles real credentials.
- Do not add generic cross-provider authentication abstractions in this change.
- SSO/SAML recovery remains out of scope; `.ssoRequired` is unchanged.

## File Structure

- `Sources/SchneeBarGitHub/GitHubConnectionSessionCoordinator.swift` — recovery transaction, credential replacement ordering, refresh-task draining.
- `Tests/SchneeBarGitHubTests/GitHubConnectionSessionCoordinatorTests.swift` — provider/session RED/GREEN contract and race tests.
- `Sources/SchneeBarGitHubFeature/GitHubConnectionRecoveryView.swift` — dedicated recovery presentation and phases.
- `Sources/SchneeBarGitHubFeature/GitHubConnectionsView.swift` — choose `Re-authenticate` or `Refresh` from normalized presentation status.
- `Sources/SchneeBarApp/GitHubConnectionsRuntimeModel.swift` — recovery orchestration, profile/cache update, auth-operation exclusivity, stale-result generations.
- `Sources/SchneeBarApp/SettingsView.swift` — recovery sheet wiring.
- `Project.swift` — add `SchneeBarAppTests` so runtime orchestration is directly testable.
- `Tests/SchneeBarAppTests/GitHubConnectionsRuntimeModelRecoveryTests.swift` — runtime state, preservation, cancellation, multi-account, and stale-refresh tests.
- `Sources/SchneeBarPreviewSupport/GitHubConnectionFixtures.swift` — deterministic authentication-required and recovery fixtures.
- `Sources/SchneeBarVisualHarness/SchneeBarVisualHarnessApp.swift` — interactive recovery visual scenes.
- `Sources/SchneeBarVisualSnapshotCLI/main.swift` — deterministic recovery snapshot registrations.
- `docs/DEVELOPMENT_PLAN.md` — mark Phase 2 credential recovery/reauthentication UX complete after verification.

## Execution Prerequisite

Merge the approved design/plan documentation into `main`, then create `feat/github-reauthentication-recovery` from that exact `main`. Production code must not be implemented on the documentation branch.

```bash
# Repository workflow:
# 1. Merge the docs PR from docs/github-reauthentication-recovery-design.
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

- [ ] **Step 1: Extend test doubles so validation failures and refresh races are controllable**

Replace the response-only transport queue with a result queue that can return HTTP responses or throw a concrete error:

```swift
private enum SessionStubResult: Sendable {
    case response(SessionStubResponse)
    case failure(URLError)
}

private actor SessionQueueTransport: GitHubHTTPTransport {
    private var results: [SessionStubResult]
    private var requests: [URLRequest] = []

    init(_ responses: [SessionStubResponse]) {
        self.results = responses.map(SessionStubResult.response)
    }

    init(results: [SessionStubResult]) {
        self.results = results
    }

    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        requests.append(request)
        guard !results.isEmpty else {
            throw URLError(.badServerResponse)
        }
        switch results.removeFirst() {
        case let .failure(error):
            throw error
        case let .response(response):
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

    func recordedRequests() -> [URLRequest] {
        requests
    }
}
```

Add an async gate for the refresh-race test:

```swift
private actor SessionAsyncGate {
    private var continuation: CheckedContinuation<Void, Never>?

    func wait() async {
        await withCheckedContinuation { continuation in
            self.continuation = continuation
        }
    }

    func open() {
        continuation?.resume()
        continuation = nil
    }
}
```

- [ ] **Step 2: Write RED tests for validation-before-persistence and account binding**

Add these test cases before adding `recover`:

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
    let old = GitHubCredential(accessToken: "test-old-token")
    let fresh = GitHubCredential(accessToken: "test-fresh-token")
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
    let old = GitHubCredential(accessToken: "test-old-token")
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
            credential: GitHubCredential(accessToken: "test-wrong-account-token")
        )
    }

    #expect(await store.credential(for: key) == old)
    #expect(await store.saves() == baselineSaves)
    #expect(await store.deletes() == 0)
}
```

Add `recoverAccountLookup401LeavesExistingCredentialUntouched`, `recoverInventory401LeavesExistingCredentialUntouched`, `recoverNetworkFailureLeavesExistingCredentialUntouched`, `recoverReturnsFreshCapabilityAssessment`, and `recoveringAccountADoesNotMutateAccountB`. Each test seeds the original credential, captures `baselineSaves`, invokes `recover`, and asserts both the expected error/result and exact credential-store contents afterward.

For the network case use:

```swift
let transport = SessionQueueTransport(results: [
    .response(SessionStubResponse(userJSON(id: 42, login: "octocat"))),
    .failure(URLError(.notConnectedToInternet)),
])
```

and assert:

```swift
await #expect(throws: URLError(.notConnectedToInternet)) {
    try await coordinator.recover(
        connection: connection,
        expectedIdentity: expected,
        credential: GitHubCredential(accessToken: "test-fresh-token")
    )
}
#expect(await store.credential(for: key) == old)
#expect(await store.saves() == baselineSaves)
```

- [ ] **Step 3: Run tests and verify RED**

```bash
mise exec -- tuist test -- -skipMacroValidation CODE_SIGNING_ALLOWED=NO
```

Expected: compile/test failure because `GitHubConnectionSessionCoordinator.recover` does not exist.

- [ ] **Step 4: Implement minimal `recover` with validate-first/persist-second ordering**

Add this method to the coordinator:

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

private func cancelAndDrainRefreshTask(for key: GitHubCredentialKey) async {
    guard let task = refreshTasks.removeValue(forKey: key) else {
        return
    }
    task.cancel()
    _ = try? await task.value
}
```

No credential delete or rollback path is added. Validation failure means no store mutation; successful validation means exactly one final save.

- [ ] **Step 5: Add RED/GREEN tests for stale refresh and cancellation during drain**

Create a controlled transport for the refresh-token POST that waits on `SessionAsyncGate` before returning the rotated credential. The test sequence is fixed:

1. Seed an expiring credential for account A.
2. Start `restore(connection:identity:clientID:)` so `refreshTasks[key]` exists and is waiting on the gate.
3. Start `recover` for the same key with `recoveryCredential`.
4. Open the refresh gate.
5. Await both operations.
6. Assert the final credential is `recoveryCredential`, proving the old refresh cannot win after recovery.

The final assertion is:

```swift
#expect(await store.credential(for: key) == recoveryCredential)
```

For cancellation, use the same blocked old-refresh setup. Start recovery, cancel its Task while `cancelAndDrainRefreshTask` is waiting, then open the old-refresh gate. The second `Task.checkCancellation()` must prevent the recovery save. Assert the old refresh result is the last durable value and the recovery credential was never written:

```swift
#expect(await store.credential(for: key) == refreshedOldCredential)
#expect(await store.credential(for: key) != recoveryCredential)
```

- [ ] **Step 6: Run the complete test suite to GREEN and commit**

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

Create `GitHubConnectionRecoveryView.swift`. The view must not expose editable endpoint, account, deployment, display-name, or client-ID fields. Its initializer is:

```swift
public init(
    context: GitHubConnectionRecoveryContext,
    phase: GitHubConnectionRecoveryPhase,
    onRetry: @escaping () -> Void,
    onOpenVerificationPage: @escaping (URL) -> Void,
    onCancel: @escaping () -> Void
)
```

The header is:

```swift
Text("Re-authenticate GitHub")
    .font(.title2.bold())
Text("\(context.displayName) · @\(context.accountLogin)")
    .font(.headline)
Text(context.host)
    .font(.caption.monospaced())
    .foregroundStyle(.secondary)
```

State rendering is:

```swift
switch phase {
case .requestingCode:
    progress(message: "Requesting a GitHub authorization code…")
case let .waitingForAuthorization(presentation):
    authorizationCode(presentation)
case .finalizing:
    progress(message: "Validating account and repository access…")
case let .failed(message):
    VStack(alignment: .leading, spacing: 12) {
        Label(message, systemImage: "exclamationmark.triangle.fill")
            .font(.caption)
            .foregroundStyle(.red)
            .textSelection(.enabled)
        Button("Try Again", action: onRetry)
            .buttonStyle(.borderedProminent)
    }
}
```

The authorization state reuses the one-time code, verification URL, and `Open GitHub Authorization Page` concepts from onboarding. Keep Cancel available in every phase.

- [ ] **Step 2: Change the connection-row action without changing other statuses**

Extend `GitHubConnectionsView` storage and initializer with `onReauthenticate`. In the action row use:

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

`Manage` remains present after this conditional. `Re-authenticate` remains enabled even when monitoring is disabled.

- [ ] **Step 3: Add deterministic recovery fixtures**

Keep the existing `.needsAttention` authentication-required row. Add:

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

- [ ] **Step 4: Generate/build before runtime wiring and commit**

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
- Consumes: `GitHubConnectionSessionCoordinator.recover(...)`, `GitHubDeviceFlowClient.begin(...)`, `GitHubDeviceAuthorizationWaiter.waitForAuthorization(...)`, `GitHubConnectionProfileStore`, `GitHubActivityProvider`.
- Produces:

```swift
var recoveringConnectionID: UUID?
var recoveryPhase: GitHubConnectionRecoveryPhase
var recoveryContext: GitHubConnectionRecoveryContext? { get }
var recoveryIsActive: Bool { get }

func beginRecovery(profileID: UUID)
func retryRecovery()
func cancelRecovery()
```

- Internal stale-result API:

```swift
private var operationGenerationByConnectionID: [UUID: UInt64]
private func advanceOperationGeneration(for connectionID: UUID) -> UInt64
private func isCurrentOperationGeneration(_ generation: UInt64, for connectionID: UUID) -> Bool
```

- [ ] **Step 1: Add `SchneeBarAppTests` to Tuist**

Add:

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

Run:

```bash
mise exec -- tuist generate
```

Expected: the generated project contains the `SchneeBarAppTests` test bundle and resolves all target dependencies.

- [ ] **Step 2: Create runtime test doubles and write RED tests**

The test file starts with:

```swift
@testable import SchneeBar
import Foundation
import SchneeBarCore
import SchneeBarGitHub
import SchneeBarGitHubActivityProvider
import SchneeBarGitHubFeature
import Testing
```

Provide an actor-backed in-memory `GitHubConnectionProfileStore` implementing all protocol requirements and a `GitHubWorkflowRunLoading` stub that returns an empty workflow-run list so the real `GitHubActivityProvider` can be instantiated deterministically.

Write these tests before adding runtime recovery methods:

```swift
@Test @MainActor
func successfulRecoveryPreservesProfileConfiguration() async throws

@Test @MainActor
func wrongAccountRecoveryDoesNotCreateOrReplaceProfile() async throws

@Test @MainActor
func recoveryWorksWhileMonitoringIsDisabled() async throws

@Test @MainActor
func recoveryMissingClientIDFailsWithoutDeletingProfile() async throws

@Test @MainActor
func cancellingRecoveryLeavesProfileAndStatusUnchanged() async throws

@Test @MainActor
func recoveringAccountADoesNotChangeAccountBOnSameEndpoint() async throws

@Test @MainActor
func beginOnboardingCancelsActiveRecovery() async throws

@Test @MainActor
func beginRecoveryCancelsActiveOnboarding() async throws

@Test @MainActor
func staleRefreshCannotOverwriteSuccessfulRecovery() async throws
```

The successful case must assert:

```swift
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
```

The wrong-account case must assert:

```swift
#expect(fixture.model.profiles == [original])
#expect(fixture.model.statusByConnectionID[original.id] == .authenticationRequired)
#expect(fixture.model.recoveringConnectionID == original.id)
```

The missing-client-ID case must assert:

```swift
#expect(
    fixture.model.recoveryPhase
        == .failed(
            message: "This saved GitHub connection is missing the client ID required for re-authentication. Add the connection again to repair it."
        )
)
#expect(fixture.model.profiles == [original])
```

- [ ] **Step 3: Run tests and verify RED**

```bash
mise exec -- tuist test -- -skipMacroValidation CODE_SIGNING_ALLOWED=NO
```

Expected: tests fail because the runtime recovery state/actions do not exist.

- [ ] **Step 4: Implement recovery state, context, and auth-operation exclusivity**

Add:

```swift
var recoveringConnectionID: UUID?
var recoveryPhase: GitHubConnectionRecoveryPhase = .requestingCode

@ObservationIgnored
private var recoveryTask: Task<Void, Never>?

@ObservationIgnored
private var operationGenerationByConnectionID: [UUID: UInt64] = [:]
```

Add:

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

var recoveryIsActive: Bool {
    switch recoveryPhase {
    case .requestingCode, .waitingForAuthorization, .finalizing:
        return recoveringConnectionID != nil
    case .failed:
        return false
    }
}
```

Authentication operations are exclusive. `beginOnboarding` must call `cancelRecovery()` before configuring onboarding. `beginRecovery` must call `cancelOnboarding()` before starting recovery.

Add:

```swift
func beginRecovery(profileID: UUID) {
    cancelOnboarding()
    recoveringConnectionID = profileID
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

- [ ] **Step 5: Implement Device Flow recovery and profile/cache update**

`startRecovery(profileID:)` snapshots the target profile and trims its stored client ID. Empty client ID immediately produces the exact failure message from Step 2.

For a valid client ID, use:

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

Before applying success require:

```swift
guard isCurrentOperationGeneration(generation, for: profile.id),
      let current = profiles.first(where: { $0.id == profile.id }),
      current.account.id == profile.account.id,
      current.connection.id == profile.connection.id
else {
    return
}
```

Build the updated profile with preserved configuration:

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

After `profileStore.save(updated)` succeeds:

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

If profile persistence fails after the credential was saved, keep the credential, leave the durable old profile untouched, set `.unavailable`, and keep the recovery sheet in `.failed`. Do not call `disconnect`.

Map account mismatch to:

```swift
"GitHub authorized a different account. Sign in as @\(profile.account.login) and try again."
```

- [ ] **Step 6: Add per-connection generation guards to normal refresh**

Implement:

```swift
private func advanceOperationGeneration(for connectionID: UUID) -> UInt64 {
    let next = (operationGenerationByConnectionID[connectionID] ?? 0) &+ 1
    operationGenerationByConnectionID[connectionID] = next
    return next
}

private func isCurrentOperationGeneration(
    _ generation: UInt64,
    for connectionID: UUID
) -> Bool {
    operationGenerationByConnectionID[connectionID] == generation
}
```

At the beginning of `refresh(profileID:)`, after resolving the target profile, capture:

```swift
let generation = advanceOperationGeneration(for: profileID)
```

Before applying a successful refresh session, before writing an authentication/network/unavailable failure status, and before persisting refreshed profile metadata, require:

```swift
guard isCurrentOperationGeneration(generation, for: profileID) else {
    return
}
```

Starting recovery advances the same generation, so a refresh started earlier cannot overwrite recovery results. Connections with different UUIDs remain independent.

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
- Modify: `Sources/SchneeBarVisualHarness/SchneeBarVisualHarnessApp.swift`
- Modify: `Sources/SchneeBarVisualSnapshotCLI/main.swift`

**Interfaces:**
- Consumes: `beginRecovery(profileID:)`, `retryRecovery()`, `cancelRecovery()`, `recoveryContext`, `recoveryPhase`, `recoveryIsActive`, `GitHubConnectionRecoveryView`.
- Produces no new domain interfaces.

- [ ] **Step 1: Wire the connection-row recovery action**

Change the existing `GitHubConnectionsView` call to include:

```swift
onReauthenticate: { id in
    githubModel.beginRecovery(profileID: id)
},
```

Keep the existing refresh callback unchanged for non-authentication states.

- [ ] **Step 2: Add a recovery sheet binding and sheet**

Add:

```swift
private var recoveryIsPresented: Binding<Bool> {
    Binding(
        get: { githubModel.recoveringConnectionID != nil },
        set: { isPresented in
            if !isPresented {
                githubModel.cancelRecovery()
            }
        }
    )
}
```

Wire:

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
        .frame(minWidth: 520, minHeight: 320)
    }
}
```

- [ ] **Step 3: Register exact visual-harness scenes**

In `SchneeBarVisualHarnessApp.swift`, add navigation/preview entries following the file's existing fixture switch style for:

```swift
GitHubConnectionsFixture.needsAttention
```

and recovery views in these phases:

```swift
.waitingForAuthorization(GitHubConnectionRecoveryFixture.authorization)
.failed(
    message: "GitHub authorized a different account. Sign in as @snow-user and try again."
)
.finalizing
```

All callbacks are inert closures in the harness.

- [ ] **Step 4: Register exact snapshot CLI scenes**

In `Sources/SchneeBarVisualSnapshotCLI/main.swift`, add deterministic snapshot names:

```text
github-connections-needs-attention
github-recovery-device-code
github-recovery-wrong-account
github-recovery-finalizing
```

Render each with the same fixed size/appearance convention already used by the current GitHub connection snapshots. Use only `GitHubConnectionRecoveryFixture` values.

- [ ] **Step 5: Generate snapshots, build, test, and commit**

```bash
mise exec -- tuist run SchneeBarVisualSnapshotCLI -- --output .visual/current
mise exec -- tuist build -- -skipMacroValidation CODE_SIGNING_ALLOWED=NO
mise exec -- tuist test -- -skipMacroValidation CODE_SIGNING_ALLOWED=NO
git add Sources/SchneeBarApp/SettingsView.swift \
  Sources/SchneeBarPreviewSupport/GitHubConnectionFixtures.swift \
  Sources/SchneeBarVisualHarness/SchneeBarVisualHarnessApp.swift \
  Sources/SchneeBarVisualSnapshotCLI/main.swift
git commit -m "feat: wire GitHub reauthentication recovery UI"
```

Inspect the generated images and confirm:

```text
- authentication-required row shows Re-authenticate rather than Refresh
- Re-authenticate remains available when monitoring is disabled
- recovery sheet shows immutable connection/account context
- no token, client secret, or private host appears
- wrong-account error names only the expected login
```

---

### Task 5: Synchronize Phase 2 documentation and verify the exact PR head

**Files:**
- Modify: `docs/DEVELOPMENT_PLAN.md`

**Interfaces:**
- No new interfaces.

- [ ] **Step 1: Update Phase 2 development-plan status**

Move credential recovery/reauthentication into implemented work with these bullets:

```markdown
- dedicated existing-connection Device Flow reauthentication
- same-account binding enforcement during recovery
- validate-before-Keychain replacement semantics
- stale refresh / recovery race protection
```

Leave these as remaining Phase 2 work:

```markdown
- broader GitHub Enterprise validation before Phase 5
- capability presentation for review requests, Checks, and deployments as those surfaces land
```

- [ ] **Step 2: Run the complete local verification gate**

```bash
mise install
mise exec -- tuist generate
mise exec -- tuist build -- -skipMacroValidation CODE_SIGNING_ALLOWED=NO
mise exec -- tuist test -- -skipMacroValidation CODE_SIGNING_ALLOWED=NO
mise exec -- tuist run SchneeBarVisualSnapshotCLI -- --output .visual/current
```

Record the final test result and exact commit SHA. Do not report success from a partial gate.

- [ ] **Step 3: Commit documentation**

```bash
git add docs/DEVELOPMENT_PLAN.md
git commit -m "docs: complete GitHub recovery milestone"
```

- [ ] **Step 4: Open a draft PR with explicit TDD evidence**

Use title:

```text
feat: add GitHub connection recovery
```

Use this PR structure with actual commit/run identifiers filled from the completed work:

```markdown
## Summary
- adds dedicated reauthentication for existing GitHub connections
- preserves account/connection/repository-selection identity
- validates account and inventory before replacing the Keychain credential
- prevents stale token refresh from overwriting recovered credentials

## TDD evidence
- Session RED commit: record the failing-test commit SHA
- Session GREEN commit: record the passing implementation commit SHA
- Runtime RED commit: record the failing-test commit SHA
- Runtime GREEN commit: record the passing implementation commit SHA

## Verification
- Tuist generate: pass
- Tuist build: pass
- Tuist test: pass
- Visual snapshots: generated and reviewed
```

Create the PR as Draft so CodeQL remains deferred under the repository's current draft gating.

- [ ] **Step 5: Verify GitHub Actions on the exact head, then mark Ready**

Require normal CI and Visual Regression to pass on the exact current PR head. If a failure occurs, add a regression test before the corresponding fix, rerun the local gate, and push the new head.

After CI and Visual Regression are green, mark the PR Ready for review so CodeQL runs. Require CodeQL to pass before merge.

- [ ] **Step 6: Final review checklist**

```text
[ ] Wrong-account authorization cannot create or replace a profile.
[ ] Failed remote validation cannot mutate the existing Keychain credential.
[ ] An older refresh task cannot overwrite the recovered credential.
[ ] Cancellation while recovery is draining an older refresh prevents the recovery save.
[ ] Disabled monitoring does not prevent explicit reauthentication.
[ ] Profile UUID, repository selection, enabled state, creation time, endpoint, and client ID survive recovery.
[ ] Two accounts on github.com remain credential-isolated.
[ ] Recovery UI contains no editable endpoint/account/client-ID fields.
[ ] CI passes on the exact PR head.
[ ] Visual Regression passes on the exact PR head.
[ ] CodeQL passes after the Ready-for-review transition.
```

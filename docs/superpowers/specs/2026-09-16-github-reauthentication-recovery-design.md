# GitHub Reauthentication Recovery Design

Status: Draft for review
Date: 2026-09-16
Base: `main@3f66f472`

## Context

SchneeBar already detects GitHub credential failures and exposes them as `GitHubConnectionPresentationStatus.authenticationRequired`. Session restoration distinguishes missing credentials, credentials that require reauthentication, and authenticated-account mismatches. The app also has a complete Device Flow onboarding path and a profile reconciler that preserves an existing profile when the same canonical endpoint and account are connected again.

What is missing is a user-facing recovery operation for an existing connection. Today an affected connection shows `Authentication required`, while the row still exposes `Refresh`. Refresh can retry session restoration and refresh a still-usable refresh token, but it cannot recover from a missing credential, an expired/unusable refresh token, or a credential that GitHub now rejects. The user can add a connection again, but that is a new-connection workflow and does not express the stronger invariant required by recovery: the newly authorized GitHub account must be the same account as the connection being repaired.

The recovery feature therefore needs a dedicated transaction that keeps the existing connection identity and settings, obtains a fresh Device Flow credential, verifies the expected account and repository access, and only then replaces the credential stored in Keychain.

## Goals

- Give `authenticationRequired` connections an explicit `Re-authenticate` action.
- Recover the existing connection instead of creating a new connection.
- Preserve the connection UUID, repository selection, monitoring enabled state, display configuration, and original creation time.
- Require the newly authenticated account ID to match the account ID already bound to the connection.
- Keep different GitHub accounts on the same endpoint isolated.
- Do not overwrite the stored credential until remote validation succeeds.
- Recompute repository inventory and capability assessment after recovery.
- Refresh Developer Activity immediately after successful recovery.
- Reuse the existing Device Flow transport, authorization waiter, credential store, endpoint model, capability evaluator, and presentation primitives where they already fit.
- Keep bearer credentials inside `SchneeBarGitHub` / app runtime boundaries and never expose them to SwiftUI presentation models.
- Cover the recovery path with deterministic unit and visual tests.

## Non-goals

- Changing the GitHub authentication method away from Device Flow.
- Adding GitHub App installation or permission-management automation.
- Solving SAML/SSO authorization recovery in this change. `ssoRequired` remains a separate status and future flow.
- Adding account switching to an existing connection. A different GitHub account must remain a different SchneeBar connection.
- Adding a generic cross-provider authentication framework before another provider requires it.
- Refactoring all onboarding and recovery UI into one generic authentication wizard.
- Implementing review-request, Checks, deployment, or Delivery Timeline activity in the same change.
- Expanding Phase 5 enterprise validation beyond using the already-configured endpoint and client ID.

## Architecture decision

Use a dedicated existing-connection recovery flow.

The recovery transaction is intentionally distinct from `Add GitHub Connection` even though both use GitHub Device Flow. New connection onboarding answers: "which account did the user authorize?" Recovery answers: "did the user authorize the exact account already bound to this connection?"

The flow is:

```text
GitHub connection row
  authenticationRequired
          |
          v
    Re-authenticate
          |
          v
GitHubConnectionsRuntimeModel
  binds recovery target profile
          |
          v
GitHubDeviceFlowClient.begin
          |
          v
GitHubDeviceAuthorizationWaiter
  returns fresh credential in memory
          |
          v
GitHubConnectionSessionCoordinator.recover
  1. authenticate fresh credential
  2. require expected account ID
  3. fetch repository inventory
  4. evaluate capabilities
  5. check cancellation
  6. save credential to expected key
          |
          v
Runtime persists same profile identity
  + updates lastConnectedAt/account metadata
  + replaces inventory/capability cache
  + resets Activity cache
          |
          v
       Connected
```

The key design rule is validate first, persist second.

## Why onboarding reuse alone is insufficient

`GitHubConnectionProfileReconciler` correctly treats endpoint + account identity as the key for finding an existing profile. That is the right rule for normal onboarding: reconnecting the same account reuses the profile, while authorizing a different account creates another profile.

That behavior is not strict enough for an explicit recovery operation. If a user chooses `Re-authenticate` on account A but completes Device Flow as account B, silently creating or switching to account B would violate the user's intent and weaken the multi-account isolation added in PR #39.

Recovery therefore carries an expected account identity from the selected profile and rejects any different authenticated account before Keychain or profile state is changed.

## Domain/session contract

Add a dedicated recovery operation to `GitHubConnectionSessionCoordinator` rather than routing recovery through `establish`.

Conceptual API:

```swift
public func recover(
    connection: GitHubConnection,
    expectedIdentity: GitHubAccountIdentity,
    credential: GitHubCredential
) async throws -> GitHubConnectionSession
```

The operation performs these steps in order:

1. Call `GitHubAccessClient.authenticatedAccount` with the supplied in-memory credential.
2. If GitHub returns 401, map to `GitHubConnectionSessionError.reauthenticationRequired`.
3. Compare `account.identity.id` with `expectedIdentity.id`.
4. If they differ, throw `accountMismatch(expectedID:actualID:)`.
5. Fetch the full `GitHubAccessInventory` using the same in-memory credential.
6. If inventory returns 401, map to `reauthenticationRequired`.
7. Evaluate `GitHubConnectionCapabilityAssessment` from the validated connection and inventory.
8. Derive the credential key from the existing connection ID and expected account identity.
9. Cancel any in-flight refresh task for that credential key.
10. Call `Task.checkCancellation()` immediately before durable credential mutation.
11. Persist the new credential exactly once through `GitHubCredentialStore.save`.
12. Return a `GitHubConnectionSession` containing the existing connection ID, authenticated account, expected credential key, inventory, and capabilities.

No credential-store mutation occurs before steps 1-10 succeed. This provides logical transactionality at the session layer: wrong-account authorization, rejected credentials, repository-inventory failure, network failure, and cancellation observed before the final save leave the previously stored credential untouched.

The cancellation check is deliberately inside the coordinator, not only in the UI runtime. A sheet dismissal can cancel the parent task after remote validation has completed; the coordinator must observe that cancellation before crossing the durable Keychain boundary.

The credential store itself remains responsible for the atomicity of its single save operation. This change does not add a second shadow credential record or a two-phase Keychain protocol.

## Runtime state and orchestration

`GitHubConnectionsRuntimeModel` owns the UI transaction because it already owns onboarding, connection presentation status, profile persistence, inventory/capability caches, and Activity invalidation.

Add recovery-specific state rather than overloading onboarding configuration state:

```swift
var recoveringConnectionID: UUID?
var recoveryPhase: GitHubConnectionRecoveryPhase
```

and a private `recoveryTask`.

Conceptual phase model:

```swift
public enum GitHubConnectionRecoveryPhase: Equatable, Sendable {
    case requestingCode
    case waitingForAuthorization(GitHubDeviceAuthorizationPresentation)
    case finalizing
    case failed(message: String)
}
```

There is deliberately no editable configuration phase. Recovery uses the existing profile's:

- deployment kind
- canonical endpoint/web base URL
- display name
- GitHub App client ID
- expected account ID
- expected account login for explanatory UI

### Begin recovery

`beginRecovery(profileID:)`:

1. Resolve the current profile by ID.
2. Require a non-empty stored client ID. If unavailable, surface a deterministic failure explaining that the connection must be added again because the Device Flow client metadata needed for recovery is missing.
3. Bind `recoveringConnectionID` to that profile.
4. Begin Device Flow against `profile.connection` using the stored client ID.
5. Present the one-time user code and verification URL.
6. Wait using the existing `GitHubDeviceAuthorizationWaiter`.
7. Pass the in-memory credential to `sessionCoordinator.recover` with `profile.account` as `expectedIdentity`.

Only one onboarding/recovery authentication transaction may be active at a time. Starting a recovery while onboarding is active, or starting onboarding while recovery is active, must not create two concurrent Device Flow transactions. The runtime should enforce this invariant explicitly rather than relying only on sheet presentation behavior.

### Successful recovery

After `sessionCoordinator.recover` succeeds, construct an updated profile that keeps:

- `id`
- `connection` identity and endpoint
- `repositorySelection`
- `isEnabled`
- `createdAt`
- `authenticationMethod`
- `clientID`

Update only metadata that can legitimately change for the same stable GitHub account ID:

- account login/display metadata from the newly authenticated account
- `lastConnectedAt`

Persist the updated profile. If profile persistence fails after credential recovery, do not delete the newly validated credential. The connection remains recoverable on the next refresh; present `.unavailable` for the immediate failure and leave the durable profile at its previous metadata rather than risking credential loss.

Then:

1. upsert the updated profile in the runtime list;
2. replace inventory and capability caches for that connection ID;
3. reset `GitHubActivityProvider` for the connection ID;
4. set presentation status from the new inventory when monitoring is enabled, otherwise `.disabled`;
5. trigger `onActivitySourceChanged`;
6. close the recovery sheet and clear recovery task state.

## Failure behavior

Recovery failures must be explicit and non-destructive.

### Wrong account

If Device Flow authenticates a different GitHub account ID:

- reject recovery with `accountMismatch`;
- do not save the new credential;
- do not create another connection;
- keep the original profile and repository selection unchanged;
- keep the connection status as `authenticationRequired` after dismissing/ending the failed attempt;
- show a message that names the expected login and asks the user to authorize that account.

The actual numeric GitHub account ID does not need to be shown to the user.

### Credential rejected during validation

401 from either account lookup or inventory validation maps to `reauthenticationRequired`. The newly obtained credential is not persisted. The recovery UI remains in a failed state with a retry path.

### Network / VPN failure

Network errors during Device Flow or validation do not change the stored credential or profile. The error message should retain the existing product distinction for enterprise connections where a VPN/private network may be required. Closing the sheet returns to the previous connection status; a later normal refresh may independently move the status to `networkUnavailable`.

### Cancellation

Cancelling the recovery sheet cancels the recovery task. The coordinator performs a cancellation check immediately before its only durable credential save, so cancellation observed before that boundary leaves Keychain unchanged. Once the validated save has completed, cancellation must not attempt rollback.

### Missing client ID

An old/malformed profile without the client ID required for Device Flow cannot use the dedicated recovery transaction. The UI should explain that it cannot re-authenticate this saved connection and that adding the connection again is required. No profile is automatically deleted.

## Presentation design

### Connection list

`GitHubConnectionsView` gains an `onReauthenticate(UUID)` callback.

For a row whose status is `.authenticationRequired`:

- replace the `Refresh` action with `Re-authenticate`;
- keep `Manage` available;
- preserve the existing orange authentication-required status treatment;
- do not disable the recovery action merely because normal monitoring cannot currently refresh.

For every other status, keep the current `Refresh` behavior.

The row remains the primary recovery entry point because it is already where the user sees the authentication failure. This avoids expanding repository management UI solely to duplicate the same action.

### Recovery sheet

Add `GitHubConnectionRecoveryView` in `SchneeBarGitHubFeature`.

The sheet displays immutable context:

- connection display name
- host
- expected `@login`

Then it renders the same Device Flow concepts already used by onboarding:

- requesting authorization code progress
- one-time user code
- `Open GitHub Authorization Page`
- final validation progress
- failure message
- cancel / retry as appropriate

Endpoint, account, deployment kind, display name, and client ID are not editable in recovery.

The existing `GitHubDeviceAuthorizationPresentation` should be reused. A generic shared wizard abstraction is not required for this change; small shared view fragments may be extracted only if duplication is material.

## Security properties

The recovery design must preserve these invariants:

1. **Account binding:** a connection ID remains bound to the same stable GitHub account ID.
2. **Endpoint binding:** recovery always uses the endpoint already stored on the target profile.
3. **Credential isolation:** the credential key remains `(connectionID, accountID)`; recovering one account cannot overwrite another account on the same GitHub endpoint.
4. **No premature credential replacement:** remote identity, inventory, capability evaluation, and a final cancellation check complete before the one credential save.
5. **No token exposure:** access and refresh tokens never enter a presentation model, log message, visual fixture, or error string.
6. **No implicit account switching:** wrong-account Device Flow is an error, not a profile-reconciliation opportunity.
7. **No destructive fallback:** failed recovery does not disconnect or delete the profile.

## Concurrency and stale-result handling

The recovery transaction is tied to the target profile ID captured at start.

Before applying successful results, the runtime must verify that the target profile still exists and still represents the same connection/account binding. If the profile was disconnected or replaced while recovery was in progress, the result must not update runtime caches or profile state.

Normal refresh and Activity polling may still be in flight when recovery begins. Recovery completion becomes the newest source of truth for that connection. The implementation should prevent a stale refresh result started before recovery from overwriting the post-recovery status/cache. The preferred mechanism is a lightweight per-connection generation/token or equivalent identity check already consistent with the runtime's stale-result handling patterns, rather than serializing all GitHub network work globally.

If current runtime behavior proves that `refresh(profileID:)` can race with recovery cache replacement, the implementation plan must include this guard as part of the recovery change rather than deferring it.

## Files expected to change

Primary implementation surface:

- `Sources/SchneeBarGitHub/GitHubConnectionSessionCoordinator.swift`
- `Sources/SchneeBarGitHubFeature/GitHubConnectionsView.swift`
- `Sources/SchneeBarGitHubFeature/GitHubConnectionRecoveryView.swift` (new)
- `Sources/SchneeBarApp/GitHubConnectionsRuntimeModel.swift`
- `Sources/SchneeBarApp/SettingsView.swift`
- corresponding visual preview/harness fixtures
- `Tests/SchneeBarGitHubTests/...`
- app/runtime or feature tests where the current project structure permits them

`GitHubConnectionProfileReconciler` should not be used to decide whether recovery may target a different account. It may remain unchanged unless a small helper is useful for building same-ID profile metadata without weakening its onboarding semantics.

## Test design

Implementation follows RED -> GREEN.

### Session coordinator tests

Required cases:

1. matching account + valid inventory saves the new credential and returns the expected session;
2. different authenticated account throws `accountMismatch` and does not save/delete credentials;
3. account endpoint 401 throws `reauthenticationRequired` without changing stored credential;
4. inventory 401 throws `reauthenticationRequired` without changing stored credential;
5. inventory/network failure leaves stored credential unchanged;
6. cancellation after remote validation but before save leaves stored credential unchanged;
7. successful recovery evaluates and returns fresh capabilities;
8. recovery of account A cannot mutate account B's credential on the same endpoint.

Credential-store test doubles should record save/delete calls so ordering and non-mutation are asserted directly.

### Runtime tests

Required cases:

1. `authenticationRequired` profile can start recovery with its existing endpoint/client ID/account;
2. successful recovery preserves profile ID, repository selection, enabled state, and createdAt;
3. successful recovery updates account metadata and lastConnectedAt;
4. successful recovery replaces inventory/capability cache and resets Activity;
5. wrong-account failure leaves profile/cache selection unchanged and status authentication-required;
6. cancel leaves durable state unchanged;
7. missing client ID produces deterministic recovery failure without deleting the profile;
8. two accounts on the same endpoint remain independent;
9. stale normal refresh cannot overwrite a newer successful recovery result;
10. onboarding and recovery Device Flow transactions cannot run concurrently.

### Presentation tests / deterministic visual fixtures

Add fixture coverage for:

- a connection card in `Authentication required` state with `Re-authenticate` action;
- Device Flow code presentation for recovery;
- wrong-account recovery error;
- finalizing state if the harness snapshots progress states.

No bearer token, refresh token, private GHES hostname, or real account data may appear in fixtures.

## Verification gates

Before merge:

1. `mise exec -- tuist generate`
2. `mise exec -- tuist build`
3. `mise exec -- tuist test`
4. deterministic visual regression workflow passes
5. normal CI passes on the exact PR head
6. CodeQL passes once the PR is ready for review under the repository's current draft gating

The PR description should include RED/GREEN evidence for the recovery contract, especially the wrong-account and no-premature-Keychain-write cases.

## Rollout and compatibility

No profile migration is required for normal current profiles because connection ID, account identity, client ID, repository selection, and enabled state already exist.

Profiles that lack a usable client ID remain readable and manageable but cannot use Device Flow recovery. They receive the explicit missing-client-ID recovery error described above. This avoids inventing a client ID or silently switching authentication configuration.

No persisted schema is added for recovery state; recovery is an in-memory UI transaction.

## Follow-up after this change

Once recovery is merged, Phase 2 connection UX is substantially complete enough to move the primary implementation focus to Phase 3:

1. review-request activity;
2. Checks/check-suite activity;
3. broader capability presentation as those surfaces land;
4. Delivery Timeline correlation UI afterward.

SSO-specific recovery and broader GHE.com/GHES validation remain Phase 5 work unless real-world testing uncovers a blocker earlier.

## Acceptance criteria

The change is complete when all of the following are true:

- An `authenticationRequired` GitHub connection exposes `Re-authenticate` from Settings.
- Reauthentication uses the existing connection endpoint and stored client ID without allowing endpoint/account editing.
- Authorizing the expected GitHub account restores the existing connection without changing its UUID or repository selection.
- Authorizing a different GitHub account is rejected and does not create or modify another connection.
- Stored credentials are not replaced until account identity and repository inventory validation succeed and cancellation is checked immediately before persistence.
- A successful recovery refreshes capability assessment and Developer Activity inputs.
- Failed or cancelled recovery leaves the existing profile intact.
- Multiple accounts on the same GitHub endpoint remain credential-isolated.
- Automated tests cover success, wrong-account, validation failure, cancellation, multi-account isolation, and stale-result behavior.
- CI, visual regression, and CodeQL pass on the merge candidate.

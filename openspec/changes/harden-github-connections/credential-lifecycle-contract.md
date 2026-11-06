# Contract: Credential migration, rotation, disconnect and recovery

Status: Proposed implementation contract; no runtime behavior is claimed. Applies to GitHub.com, GHE.com and verified GHES.

## Identity and persistence keys

A **provider principal** is the canonical `(deploymentKind, HTTPS origin, numeric accountID)`. An **authorization enrollment** is a separately created, immutable random `enrollmentID` (UUID) scoped to `(principal, GitHub App clientID, authorizationPurpose)`, where purpose is `read` or `write`. An enrollment identifies one consent/token lifecycle and is **never reused**, even after disconnect/reconnect to the same account, host and App. The existing profile UUID is a local association, **not** account authorization; unresolved/legacy App identity is treated as `unknown`, never silently upgraded to write. Multiple enrollments may share a principal but never share secret storage or cleanup ownership.

**Storage**: the V2 Keychain item address MUST include a versioned service/account namespace, purpose, and immutable enrollmentID (no token bytes in the address). A journal links its exact Keychain record reference to the enrollment and monotonic epoch. Legacy `GitHubCredentialKey(connectionID, accountID)` is read only through a dedicated exact-legacy migration adapter; before promotion it must be reserved against concurrent migration/cleanup, and no V2 enrollment is ever stored at that legacy address. The application MUST NOT identify a V2 record by the five-field principal/App tuple alone.

Per enrollmentID **and reserved legacy Keychain address**, one application-owned coordinator arbitrates all mutation operations including OAuth refresh, Keychain migration, recovery, explicit disconnect and profile delete. The coordinator has a strictly monotonic **epoch** and a durable disconnected tombstone. Background async completion SHALL check that its captured epoch remains current before any write. Concurrent app instances or helper writers require a separately verified cross-process lock/fencing mechanism; do not claim in-memory actors alone solve cross-process races.

## State machine

| State | May send credential? | Transition |
| --- | --- | --- |
| `legacyActive` | Only after endpoint/account/expiry validation and current epoch check | `prepareMigration`, `disconnect`, `reauthRequired` |
| `migrationPrepared` | No migration-candidate network use | `dpActive` only after DPK read-back and epoch check, or `legacyActive` on safe rollback |
| `dpActive` | Yes, only after current binding, expiry and epoch check | `refreshInFlight`, `disconnect`, `reauthRequired` |
| `refreshInFlight` | Do not send stale candidate; share single refresh flight | `dpActive` on durable rotation, `reauthRequired` on uncertain or failed rotation, `disconnected` on disconnect |
| `reauthRequired` | No | Explicit verified reconnect or disconnect |
| `disconnected` | No; absorbing for old epoch | New explicit connection uses a **new** epoch and new identity association |

The persistent metadata journal records immutable enrollmentID, epoch, lifecycle state, exact Keychain record *references*, legacy address reservations, and migration generation without token bytes. No invalid state may be hidden by silently reading the old Keychain store after a disconnect tombstone has been created.

## Transaction rules

1. Before normal migration, acquire the per-key mutation lease and persist a migration intent for epoch E. Refuse unsafe migration if a refresh, recovery or disconnect is in progress.
2. Read exactly the expected legacy Keychain account; verify origin/account, token shape and local expiry policy. Stage DPK record without deleting legacy.
3. Read back the DPK record in the **new enrollment-specific namespace** and verify exact record identity/secret equality in memory. Persist promotion to `dpActive` at the same epoch before deleting legacy; legacy deletion is **idempotent cleanup**, not the authoritative state change.
4. If an epoch changed (including a disconnect), discard staged candidate and do not refresh or persist it. A disconnected tombstone wins over any stale load, refresh, or migration completion.
5. Refresh uses a single flight within the same identity/epoch. A successful provider-side rotation invalidates its old refresh token; save the newly rotated pair before granting any requests to use it. A crash after server rotation but before durable save may be unrecoverable locally: show **reauthentication required**, never promise rollback to a still-valid old token.
6. Token delete and profile delete are distinct steps. Normal disconnect persists a durable `disconnect` intent/tombstone naming **enrollmentID, epoch and exact owned record references** before Keychain/profile mutations, then advances the epoch and cancels/drains flights. If journal persistence is unavailable, do not claim recoverable full cleanup. Provide an explicitly warned emergency local token deletion path without a false persistence guarantee.
7. Crash/restart replays only the specific enrollmentID/epoch and pending cleanup operations, not old credentials. A fresh connection with the same GitHub identity **always** receives a new enrollmentID, V2 Keychain namespace and epoch, and cannot be affected by stale operations from the old enrollment. Old cleanup MUST NOT use a principal-wide or clientID-wide delete query.

## Required tests

- Two concurrent migration/refresh operations and an overlapping disconnect; no stale Keychain credential resurrection.
- Cancellation after promotion but before legacy cleanup; restart obeys DPK authority and cleans only old exact record.
- Client ID/account/host binding mismatch; zero OAuth/API sends for mismatched identity.
- Crash after provider accepts rotation but before durable write; no use of invalidated previous refresh token, explicit reauth.
- Keychain DPK access behavior on signed real macOS; do not infer from mock status.
- Separate read/write credentials for the same account are never interchangeable.

## Reconnection and legacy namespace isolation

1. Disconnect profile A for a principal: persist a tombstone for A's enrollment(s), capture exact Keychain item addresses, and permit cleanup only for those addresses and that profile's history scope.
2. Reconnect the same principal/App, creating profile B: allocate **fresh** `enrollmentID=B` and its own V2 Keychain item(s) before granting access. Never treat the old A tombstone as applying to B.
3. Deferred cleanup for A MUST compare its enrollmentID, epoch, exact item address and stored ownership marker before each destructive operation. Ambiguous or missing ownership is a `cleanupBlocked` outcome; it MUST NOT fall back to a broad `service+accountID` Keychain deletion.
4. The legacy v1 Keychain key `(connectionID, accountID)` MUST be reserved while v1→v2 migration runs. An old migration must not delete a legacy item now bound to a different enrollment, nor use an unverified new user's profile ID as its only binding evidence.
5. The per-enrollment and per-legacy-address coordination policy MUST also cover reauthentication and concurrent process/helper operation; if cross-process fencing is unavailable, refuse unsafe concurrent writes rather than claiming safety.

### Acceptance sequence

- Connect A (read/write separately) → disconnect A → reconnect same canonical account/App as B → resume delayed cleanup A → B's Keychain item and profile remain intact and usable.
- Simultaneous V1 migration, disconnect and B enrollment: no A token reappears and no B record is deleted by v1 fallback cleanup.
- Attempt broad or ambiguous Keychain deletion: **zero** V2 items deleted and a durable blocked cleanup record remains.
- Two distinct App client IDs or authorization purposes for one principal: distinct enrollmentIDs, no cross-purpose credential reuse.

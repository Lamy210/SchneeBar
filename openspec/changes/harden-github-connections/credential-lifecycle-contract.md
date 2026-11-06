# Contract: Credential migration, rotation, disconnect and recovery

Status: Proposed implementation contract; no runtime behavior is claimed. Applies to GitHub.com, GHE.com and verified GHES.

## Identity and persistence keys

Credential identity is the canonical `(deploymentKind, HTTPS origin, numeric accountID, GitHub App clientID, authorizationPurpose)`. `authorizationPurpose` is `read` or `write`. The existing profile UUID is a local association, **not** account authorization; unresolved or legacy App identity is treated as `unknown`, never automatically upgraded to write.

Per credential key, one application-owned coordinator arbitrates all mutation operations including OAuth refresh, Keychain migration, recovery, explicit disconnect and profile delete. The coordinator has a strictly monotonic **epoch** and a durable disconnected tombstone. Background async completion SHALL check that its captured epoch remains current before any write. Concurrent app instances or helper writers require a separately verified cross-process lock/fencing mechanism; do not claim in-memory actors alone solve cross-process races.

## State machine

| State | May send credential? | Transition |
| --- | --- | --- |
| `legacyActive` | Only after endpoint/account/expiry validation and current epoch check | `prepareMigration`, `disconnect`, `reauthRequired` |
| `migrationPrepared` | No migration-candidate network use | `dpActive` only after DPK read-back and epoch check, or `legacyActive` on safe rollback |
| `dpActive` | Yes, only after current binding, expiry and epoch check | `refreshInFlight`, `disconnect`, `reauthRequired` |
| `refreshInFlight` | Do not send stale candidate; share single refresh flight | `dpActive` on durable rotation, `reauthRequired` on uncertain or failed rotation, `disconnected` on disconnect |
| `reauthRequired` | No | Explicit verified reconnect or disconnect |
| `disconnected` | No; absorbing for old epoch | New explicit connection uses a **new** epoch and new identity association |

The persistent metadata journal records epoch, lifecycle state, Keychain record *references*, and migration generation without token bytes. No invalid state may be hidden by silently reading the old Keychain store after a disconnect tombstone has been created.

## Transaction rules

1. Before normal migration, acquire the per-key mutation lease and persist a migration intent for epoch E. Refuse unsafe migration if a refresh, recovery or disconnect is in progress.
2. Read exactly the expected legacy Keychain account; verify origin/account, token shape and local expiry policy. Stage DPK record without deleting legacy.
3. Read back the DPK record and verify exact record identity/secret equality in memory. Persist promotion to `dpActive` at the same epoch before deleting legacy; legacy deletion is **idempotent cleanup**, not the authoritative state change.
4. If an epoch changed (including a disconnect), discard staged candidate and do not refresh or persist it. A disconnected tombstone wins over any stale load, refresh, or migration completion.
5. Refresh uses a single flight within the same identity/epoch. A successful provider-side rotation invalidates its old refresh token; save the newly rotated pair before granting any requests to use it. A crash after server rotation but before durable save may be unrecoverable locally: show **reauthentication required**, never promise rollback to a still-valid old token.
6. Token delete and profile delete are distinct steps. Normal disconnect persists a durable `disconnect` intent/tombstone before Keychain/profile mutations, then advances the epoch and cancels/drains flights. If journal persistence is unavailable, do not claim recoverable full cleanup. Provide an explicitly warned emergency local token deletion path without a false persistence guarantee.
7. Crash/restart replays only the current epoch and pending cleanup operations, not old credentials. A fresh connection with the same GitHub identity obtains a new profile/epoch and is not affected by stale operations.

## Required tests

- Two concurrent migration/refresh operations and an overlapping disconnect; no stale Keychain credential resurrection.
- Cancellation after promotion but before legacy cleanup; restart obeys DPK authority and cleans only old exact record.
- Client ID/account/host binding mismatch; zero OAuth/API sends for mismatched identity.
- Crash after provider accepts rotation but before durable write; no use of invalidated previous refresh token, explicit reauth.
- Keychain DPK access behavior on signed real macOS; do not infer from mock status.
- Separate read/write credentials for the same account are never interchangeable.

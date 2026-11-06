# Contract: Durable local cleanup and truthful GitHub disconnection

Status: Proposed. Remote GitHub App grant revocation is not asserted by local deletion.

## Record

A profile-independent, **nonsecret** CleanupLedger is stored outside the deletable connection profile/index. Each entry contains: operationID UUID, old source profile UUID, monotonic operation epoch, creation/update timestamps, step states (`pending|succeeded|failed`) for `tokenDeletion`, `profileDeletion`, `historyDeletion`, bounded error code and retry count. Never persist tokens, Client Secrets, private repository contents, arbitrary error strings, or OAuth codes in this ledger.

Write atomically with owner-only filesystem permissions; the ledger must remain readable after a profile is removed. The global Security/Cleanup UI lists pending or failed operations even when the old connection row no longer exists.

## Disconnect flow

1. Persist disconnect tombstone and cleanup record **before** normal credential/profile removal. On failure to persist, do not claim full cleanup can be tracked; emergency token deletion remains an explicit fallback with a warning.
2. Cancel/drain in-flight refresh/recovery, increment operation epoch and stop polling. All late write attempts are fenced by epoch/tombstone.
3. Delete the *exact* old Keychain items, then the old profile, then history scoped strictly to old `sourceID`; durably mark each successful step. A failure never converts to success through `try?`.
4. On partial failure, show a persistent `cleanup pending/failed` state and a retry action in the **global** Security/Cleanup screen. Retrying never reintroduces credentials, restores the old profile, contacts GitHub, or deletes data for a newly reconnected account.
5. Mark completed and retire ledger entry only after all local cleanup steps have succeeded; retain minimal no-secret audit/status until acknowledged, under a documented retention policy.
6. Never say the *remote* GitHub grant was revoked unless provider-side evidence confirms it; link to the provider's App authorization-management UI.

## Required fault injection

- Token deleted + profile deleted + history delete failed + relaunch: pending record remains visible, retry safely removes old history, no GitHub requests or restored credentials.
- Disk write failure, malformed history backing file, duplicate disconnect, and restart at each step.
- Reconnect to the same numeric GitHub account while previous cleanup remains pending: new source UUID remains untouched.
- Legacy Keychain migration and disconnect concurrently: no old credential resurrection.

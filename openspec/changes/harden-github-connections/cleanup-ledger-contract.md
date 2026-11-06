# Contract: Durable local cleanup and truthful GitHub disconnection

Status: Proposed. Remote GitHub App grant revocation is not asserted by local deletion.

## Record

A profile-independent, **nonsecret** CleanupLedger is stored outside the deletable connection profile/index. Each entry contains: operationID UUID, old source profile UUID, monotonic operation epoch, creation/update timestamps, step states (`pending|succeeded|failed|blocked`) for `tokenDeletion`, `profileDeletion`, `historyDeletion`, **immutable enrollmentID and exact owned Keychain reference(s)**, bounded error code and retry count. Never persist tokens, Client Secrets, private repository contents, arbitrary error strings, or OAuth codes in this ledger.

Write atomically with owner-only filesystem permissions; the ledger must remain readable after a profile is removed. The global Security/Cleanup UI lists pending or failed operations even when the old connection row no longer exists.

## Disconnect flow

1. Persist disconnect tombstone and cleanup record **before** normal credential/profile removal. On failure to persist, do not claim full cleanup can be tracked; emergency token deletion remains an explicit fallback with a warning.
2. Cancel/drain in-flight refresh/recovery, increment operation epoch and stop polling. All late write attempts are fenced by epoch/tombstone.
3. Delete the *exact* old-enrollment Keychain items (verify item address/owner/epoch), then the old profile, then history scoped strictly to old `sourceID`; durably mark each successful step. A failure never converts to success through `try?`; an unknown owner yields a blocked state, never a broad delete.
4. On partial failure, show a persistent `cleanup pending/failed/blocked` state and a retry action (where retry is meaningful) in the **global** Security/Cleanup screen. Retrying never reintroduces credentials, restores the old profile, contacts GitHub, or deletes data for a newly reconnected account.
5. Mark completed and retire ledger entry only after all local cleanup steps have succeeded; retain minimal no-secret audit/status until acknowledged, under a documented retention policy.
6. Never say the *remote* GitHub grant was revoked unless provider-side evidence confirms it; link to the provider's App authorization-management UI.

## Required fault injection

- Token deleted + profile deleted + history delete failed + relaunch: pending record remains visible, retry safely removes old history, no GitHub requests or restored credentials.
- Disk write failure, malformed history backing file, duplicate disconnect, and restart at each step.
- Reconnect to the same numeric GitHub account while previous cleanup remains pending: new source UUID remains untouched.
- Legacy Keychain migration and disconnect concurrently: no old credential resurrection.

## Unreadable shared-history file: recovery boundary

The current `ApplicationSupportDeliveryHistoryStore` holds multiple connection scopes in **one** JSON payload. `delete(sourceID:)` must decode the shared payload before removing one scope. A corrupted JSON document, unsupported schema or unsafe/symlinked backing path makes **targeted deletion impossible** without risking another account's data. Blind retry is not a remedy for persistent corruption.

- On any unreadable/unsupported/unsafe shared file, set `historyDeletion=blocked`, retain the original file **unchanged**, keep ledger visible after relaunch and explicitly state that local history may remain. Do not discard other accounts' history or mark `localRemoved`.
- Automatic retries are allowed only after the relevant condition changes (e.g., a repair validated by a supported parser, an administrator choosing a safe file location, or a valid backup). Repeated errors must not loop or spin.
- An **existing independently verified backup** may be restored only to a staging location and checked for supported schema, safe path ownership, scope consistency and completeness. A restoration that would lose unrelated scopes must be rejected or require explicit consent. Restored/remaining backup copies still containing deleted-account history count as retained local data until themselves disposed of under an explicit policy.
- Where targeted scope deletion remains impossible, offer two honest outcomes: (a) keep the blocked file and show incomplete cleanup, with optional safe export for manual recovery; (b) user-initiated, **explicit irreversible whole-history purge** that warns it deletes **all** accounts' stored history, validates that the precise backing path is app-owned/safe, and does not silently delete backups. The application MUST NOT default to option (b).
- A whole-file purge is allowed to mark historical cleanup complete **only after** all known app-owned copies containing the old history are removed; where scope completeness cannot be verified, report `partial/unknown`, not a false guarantee of erasure.
- Future per-scope history files may reduce the blast radius but migration and retention of the old aggregate file need their own verification. No automatic cross-scope data loss.

### Fault-injection acceptance

1. Two profiles A/B in a valid shared history: disconnect A removes A scopes, leaves B byte-for-byte equivalent after round-trip.
2. Corrupt JSON, unsupported schema or symlink target: disconnect A produces durable `blocked`, no automatic file deletion and no change to B or the backing file after 3 retries/relaunch.
3. User rejects whole-history purge: blocked state remains; no deletion is reported.
4. User explicitly approves whole-history purge after loss warning: only verified app-owned file(s) are deleted, backup status is disclosed, all-account data-loss consent recorded without secrets, and cleanup status is truthful.
5. Disconnect A then re-enroll same GitHub identity as B: old cleanup cannot delete B's V2 Keychain items or profile/history source, including when the old ledger resumes after restart.

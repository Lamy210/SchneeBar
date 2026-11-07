# GitHub credential enrollment generation policy (pre-integration)

Status: proposed deterministic domain implementation. Depends on opt-in V2 Keychain foundation #377. Tracks #368 and OpenSpec #367.

## What this code proves

- A fresh enrollment UUID and read/write purpose distinguish an authorization lifecycle from the canonical GitHub account principal.
- An explicit phase machine represents prepared, legacy-active, migration-prepared, DPK-active, refresh-in-flight, reauthentication-required and disconnected state. A disconnected generation has no valid transition back to active.
- Every transition compares its expected generation; stale asynchronous completions and old cleanup scopes are rejected even when provider/account/App identity is the same.
- A journal actor serializes transitions in **one process** and delegates persistence through a replace-all protocol. The replace result must be durable before a transition is acknowledged. A failed/uncertain replace invalidates the actor's cache so the next operation reloads the authoritative snapshot.
- The journal has **no production persistence adapter and is not called by the shipping auth coordinator**. Test fixtures simulate persistent state, write failure before commit, and an error after commit.

## Security invariants and explicit gaps

This policy is necessary but NOT sufficient for production credential migration. It does not read, refresh, add, migrate or delete real tokens and cannot enforce correctness across multiple app processes. A future persistence adapter must implement exact app-owned paths, exclusive cross-process fencing, transactional/durable replacement, safe file permissions, symlink protection, schema/identity verification, and crash/power-loss evidence before it may be wired into the GitHub session coordinator.

No secret bytes belong in this state. It holds nonsecret account/origin/App identifiers and the storage-account key, and tests verify Codable shape excludes tokens.

## Validation

- Deterministic pure Swift lifecycle tests for stale generation, reauth, disconnect/reconnect isolation, read/write separation, invalid origin and serialization.
- In-memory synchronous journal fixture tests for duplicate enrollment, restart reload, stale completion, malformed duplicate snapshot, and failures before/after replacing a persisted snapshot.
- Swift unit tests and native CI are required before merging this policy. **No real-Mac Keychain, signed-app or lock/sleep behavior is implied by a green CI status.**

See: docs/GITHUB_DPK_V2_FOUNDATION.md; Issue #368; OpenSpec PR #367.

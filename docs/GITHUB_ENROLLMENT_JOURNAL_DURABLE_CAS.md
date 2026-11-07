# Experimental durable enrollment journal CAS adapter

This follows PR #379 (already merged) and Issue #368. **No production GitHub credential path uses this adapter.**

## Implemented mechanisms

- Every reader and compare-and-replace writer uses the same persistent, owner-only advisory flock file. A write checks the on-disk expected snapshot while holding LOCK_EX, preventing lost writes among cooperating app/helper processes.
- File updates are written to a unique 0600 temporary file, fsync-ed, atomically renamed, and followed by directory fsync. If a failure occurs after rename, the journal actor discards its cache and requires reloading the potentially advanced generation.
- Accept only a pre-created owner-owned 0700 directory under trusted app Application Support parents. Files must be regular, singly linked and owner-only; final-component symlinks rejected. Bounded 1 MiB JSON envelope uses a schema version and rejects invalid/duplicate enrollment identity.
- Only nonsecret enrollment metadata, no tokens, refresh material, device codes or authorization headers.

## Non-goals and remaining security gates

This prevents lost JOURNAL updates across compliant processes, not arbitrary Keychain writes. Integration with the SessionCoordinator, secure directory provisioning, exact legacy item reservation, token-rotation fencing, crash/power-loss experiments and signed Mac lock/unlock tests remain outstanding. Caller-provided path parents must be independently verified; this adapter checks its final directory inode but not all intermediate ancestors. Same-UID malicious process interference is outside this current trust boundary.

## Test plan

Two journal actors sharing one directory and stale CAS; re-open and readback; same-account disconnect/reconnect isolation; corrupt data, unknown schema, unsafe permissions and symlink rejection; no rewrite of corrupted backing file. Actual abrupt process termination and true multi-process stress must be separately exercised before enabling real token migration.

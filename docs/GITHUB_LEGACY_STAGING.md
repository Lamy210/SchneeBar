# Verified-readback legacy migration staging (non-destructive)

Status: experimental foundation for [#368](https://github.com/Lamy210/SchneeBar/issues/368). Depends on #377, #379 and #380. This change is **not integrated into the shipping GitHub session coordinator**.

## Scope

A new `GitHubCredentialMigrationStager` accepts a previously verified `GitHubLegacyMigrationBinding`, exact `GitHubCredentialKey(connectionID, accountID)`, current durable enrollment generation, read-only legacy store and insert-only V2 Data Protection Keychain adapter.

1. Reject unsupported purpose (write authorization is never silently migrated), absent profiles, mismatched account/App/origin/connection ID and legacy token records missing an exact endpoint binding.
2. Load one exact legacy record without deleting it; persist `migrationPrepared` by journal CAS before V2 I/O.
3. Insert V2 data only into the immutable enrollment-specific slot if absent, or verify exact equality with an already staged item after interruption.
4. Read V2 credential back and compare the **entire credential value** before persisting `dpActive` through another journal CAS.
5. On interruption, mismatched V2 item, failed readback, stale generation or disconnect, leave the **legacy token unchanged**. An orphan V2 item is not usable by the production app (no wiring), and future cleanup must prove exact enrollment ownership.

## Remaining production preconditions (DO NOT enable by default)

- `GitHubLegacyMigrationBinding` is supplied by the caller. Constructing it is **not cryptographic or network proof**. Verify actual authenticated `/user`, profile ID, canonical HTTPS origin, App client ID, authentication method and SSO authorization before calling.
- Ensure all old Keychain write/delete/refresh paths and app/helper processes are fenced by the same durable coordinator. This current stager intentionally **does not reserve the old Keychain item** or reconcile simultaneous refresh/token rotation.
- Add a persistent exact legacy-item reservation and account/App-verified migration journal transaction. Verify signed Mac DPK access classes, crash/power-off, lock/unlock and source token expiration against real provider behavior.
- Define retained-old-token cleanup and revocation semantics in a separate reviewed change; **never** delete legacy on partial copy, readback or new journal state alone.
- Keep the previous shipped authentication code path unchanged until all security/compatibility gates succeed. No automatic migration, new UI or secret logging is introduced here.

## Tests

Synthetic, no-secret fixtures cover verified copy and non-deletion, staged resume after crash, account/client/endpoint mismatch, absent legacy, preexisting mismatched V2, readback failure, an intervening disconnect and prohibition on treating read access as write authorization. No real Keychain data or GitHub API requests are used.

## PR #381 API alignment

The destination insert method takes the immutable `migrationPrepared` **enrollment lifecycle snapshot**, rather than a separately supplied raw V2 Keychain account key, matching the production V2 store's endpoint, token-shape and phase validation. The synthetic test store checks the prepared phase, read purpose and endpoint binding before accepting an insert. A broader persisted-journal/credential mutation lock is still required before runtime activation.

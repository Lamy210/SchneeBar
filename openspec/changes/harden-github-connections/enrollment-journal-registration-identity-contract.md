# P0 follow-up: validate enrollment identity at registration boundary

## Gap
`GitHubCredentialEnrollmentJournal.register` checks that a new lifecycle is prepared or a verified legacy registration at generation 1. But `GitHubCredentialEnrollmentLifecycle` is publicly `Codable`: decoding its fields bypasses its throwing initializer. Passing an otherwise plausible prepared/legacyActive snapshot with a malformed HTTPS origin, numeric account or App client ID could reach a permissive journal persistence adapter without the same validation performed by the hardened file adapter.

## Contract
- Before attempting `compareAndReplace`, `register` must reject a decoded enrollment if it fails `isValidPersistedSnapshot()`. Keep existing generation=1 and allowed registration phase checks and duplicate-enrollment protection.
- The registration boundary is invariant across adapters: no invalid identity is given to the persistence adapter even if a test or future in-memory/cloud backend does not independently validate it.
- Preserve existing valid prepared and legacyActive registrations. Do not read or change Keychain, rotate tokens, delete legacy credentials, authorize new GitHub capabilities, or bypass registration journal CAS rules.

## Tests
- Decode forged `prepared` snapshots with HTTP origin, nonnumeric account ID or empty client ID. Reject each with `invalidSnapshot`, prove the persistence adapter stayed empty, then register the original valid lifecycle.
- Decode a forged `legacyActive` snapshot with negative account ID. Confirm the same fail-closed behavior and allow the legitimate verified-legacy lifecycle.
- macOS CI Build/Test, Visual Regression and OpenSpec strict validation must succeed on the final head before merging to `main`. Sync to `integration/schneerunner` separately.

## Safety boundaries
Structural validation is **not** evidence of real provider account identity, App authorization, Keychain safety or journal lease/generation fencing. Existing P0 #368 and #396 gates remain open.

# P0 follow-up: enforce active V2 Keychain enrollment binding on reads

## Gap
An opt-in Data Protection Keychain (DPK) V2 store already uses an exact scoped key and checks the endpoint before **insert**. Its existing `load(for: GitHubCredentialEnrollmentKey)` is an intentionally low-level readback primitive for staged migrations, not permission to use that credential in a live authenticated session. Calling that primitive directly from a future runtime without checking the persisted enrollment phase and endpoint could activate a staged, stale or cross-endpoint token.

## New safe read boundary
- Provide `loadActive(for: GitHubCredentialEnrollmentLifecycle)` on the V2 store. Before Keychain I/O, require `phase == .dpActive` and generation >= 2 (a newly prepared enrollment starts at generation 1). Also validate the decoded identity fields by reconstructing the domain enrollment validation (HTTPS-only canonical origin, numeric account ID and nonempty client ID) before reading Keychain. All other states (including prepared, migrationPrepared, disconnected, refreshInFlight, reauthRequired) fail closed with a typed inactive-enrollment error.
- When a V2 record exists, require exact `credential.endpointIdentity == enrollment.canonicalWebOrigin`, nonempty/bounded access token and a nonempty/bounded refresh token if present. A missing record returns nil. Invalid records are rejected, never normalized or written back.
- Keep `load(for: key)` for read-back only: the migration stager must be allowed to inspect a staged record before transitioning its durable journal to dpActive. Do not change the existing legacy Keychain store, service or DPK keys, delete or migrate any credentials, or alter refresh behavior.
- Do not require token expiry for GHES on this slice: hosted/GHES issuance policy is enforced by separate device-flow and session boundaries. Do not infer account identity from tokens, expose secrets in errors or log credentials.

## Non-guarantees / safety boundary
The passed lifecycle object is **not** authoritative merely because its fields are correct. The future runtime coordinator must re-read the **durable enrollment journal under its cross-process generation fence**, verify connected account/app/install binding, and check the credential's current expiry/refresh state before returning authorized API capability. `loadActive` is necessary but not sufficient. It is not wired into the shipping app.

## Tests and gates
- Deterministic pure policy tests: dpActive allow, staged/inactive/refresh/disconnected reject, exact endpoint mismatch/nil reject, empty/oversized access/refresh tokens reject, exact GHES custom origin allow, forged Codable enrollment identity/generation reject.
- Async API test proves a prepared lifecycle is rejected **before any Keychain query** on unsigned CI.
- Existing Keychain tests and migration staging tests remain green. Real signed Mac Keychain access, locked/unlocked transitions, crash-safe refresh rotation and migration rollback remain required under issue #368.
- macOS CI Build/Test, Visual Regression and OpenSpec strict validation must pass on the final PR head; merge to `main` only after full checks and review. Sync to `integration/schneerunner` separately.

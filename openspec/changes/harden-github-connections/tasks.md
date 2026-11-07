# Tasks: Harden GitHub connections

## 1. Baseline and adversarial fixtures

- [x] 1.1 Identify Keychain, OAuth Device Flow, refresh, endpoint, HTTP and write/disconnect code paths; evidence: docs/SECURITY_HARDENING_PLAN.md.
- [x] 1.2 Record primary Apple, GitHub and RFC references and existing ADR-0002; evidence: docs/SECURITY_HARDENING_PLAN.md.
- [ ] 1.3 Build synthetic token, Keychain and redirect test fixtures without real secrets; verify tests reproduce baseline behavior.
- [ ] 1.4 Run OpenSpec strict validation and record CLI output; verify no structural warnings/errors before runtime implementation.

## 2. SEC-001 Keychain storage and migration (issue #368)

- [ ] 2.1 Reproduce current Keychain protection behavior on a signed real Mac, including lock state; verify recorded OS, codesign/team and accessibility observations.
- [ ] 2.2 Add exact-account DPK/legacy synthetic lookup and failure tests; verify unrelated Keychain items are never enumerated or deleted.
- [ ] 2.3 Implement DPK add/query/update/delete consistently; verify expected accessibility behavior across relaunch and background monitoring.
- [ ] 2.4 Implement read-back-verified staged migration preserving valid old items until success; verify retry, crash and partial failure fixtures.
- [ ] 2.5 Add endpoint/account consistency checks around migration and report recoverable errors; verify account mismatch does not mutate old credential.
- [ ] 2.6 Measure interactive write-token accessibility tradeoffs; verify lock-screen restrictions without breaking intended read-only background polling.

## 3. SEC-002 Issuance and refresh (issue #369)

- [ ] 3.1 Prove expiring-token semantics for GitHub.com/GHE.com and supported GHES fixtures; verify request/response evidence by host category.
- [ ] 3.2 Require expiring metadata for new supported credentials and provide explicit legacy handling; verify malformed/nonexpiring new responses are not persisted.
- [ ] 3.3 Preserve single-flight refresh, rotated-token atomic update and generation invalidation; verify concurrent/stale/canceled refresh tests.
- [ ] 3.4 Test revoked, expired and account/endpoint mismatch responses with full profile recovery; verify zero wrong-origin bearer requests and no identity overwrite.

## 4. SEC-003 Transport redirection and diagnostics

- [ ] 4.1 Implement per-origin redirect refusal for secret-bearing OAuth/REST requests; verify mock URLProtocol/delegate blocks cross-host and same-host-unapproved 30x.
- [ ] 4.2 Test scheme downgrade, custom ports, malformed Location, encoded host and body/header preservation; verify zero secret-bearing requests to forbidden destinations.
- [ ] 4.3 Audit HTTP failure messages, logging, crash diagnostics and character-event projections; verify token/device-code canary strings never appear.

## 5. SEC-004 Privilege checks and SEC-005/006 connection UX

- [ ] 5.1 Define the read-only and separately scoped write-capable GitHub App credential model with GHES constraints; verify user/App permission matrix review.
- [ ] 5.2 Enforce explicit user-initiated write policy at mutation service boundary, not only UI; verify untrusted events and read-only credentials cause zero mutation calls.
- [ ] 5.3 Update onboarding to show trustworthy host, known/unknown App ownership and device phishing guidance; verify spoofed Client ID/host test cases.
- [ ] 5.4 Preserve stable account identity during reauthentication and multiple same-host accounts; verify mismatch and duplicate-profile tests.
- [ ] 5.5 Distinguish local credential/profile/history deletion results from GitHub remote grant revocation; verify cleanup error remains visible and retryable.
- [ ] 5.6 Provide official GitHub app authorization review/incident guidance; verify UI does not claim 2FA/passkey status or remote revocation without evidence.

## 6. Integration and release gate

- [ ] 6.1 Run focused Swift security tests and existing SchneeBar regression/visual suites; verify checks green on exact commit.
- [ ] 6.2 Run signed real-Mac Keychain/device-auth/redirect smoke with synthetic credentials; verify recorded reproducible test evidence.
- [ ] 6.3 Review rollback and restore of legacy credentials, logging and remaining risks; verify maintainer acceptance before enabling GitHub-triggered Companion events.

## 7. P0/P1 review closure contracts (implementation remains pending)

- [ ] 7.1 Implement per-credential durable migration epoch/tombstone and exclusive update coordination; verify refresh-vs-migration-vs-disconnect concurrency, reboot and stale-write fixtures from credential-lifecycle-contract.md.
- [ ] 7.2 Verify refresh-token rotation crash window requires reauthentication rather than unsafe rollback; record mock/provider-backed behavior and no invalid credential reuse.
- [ ] 7.3 Implement independently enrolled read/write App credential namespaces and one-shot confirmed intent; verify account/host/repository mismatch and legacy broad-scope read token produce zero unauthorized writes.
- [ ] 7.4 Implement a durable profile-independent CleanupLedger and global retry UI; verify history-delete failure after profile deletion survives relaunch and never restores credentials.
- [ ] 7.5 Audit durability/storage-protection of lifecycle journal, credential metadata and cleanup records; verify no tokens are written outside Keychain.
- [ ] 7.6 Review GHES write-permission evidence and owned-App expiry compatibility against real deployment matrix; verify unknown cases remain disabled rather than inferred.

## 8. Re-review closure: enrollment identity, write migration, corrupted history

- [ ] 8.1 Implement immutable enrollmentID-specific V2 Keychain namespaces distinct from existing `connectionID+accountID` legacy storage; verify A disconnect → B reconnect same identity → A cleanup cannot remove B.
- [ ] 8.2 Implement physical legacy-item reservation and owner/epoch fencing for v1→v2 migration; verify concurrent refresh/reconnect/disconnect and exact-key-only cleanup across restart.
- [ ] 8.3 Record reviewed write-App deployment matrix, explicit strictWriteGrantV2 release gate, user-visible breaking-change messaging and non-escalating rollback; verify legacy wide-scope token cannot issue writes after strict cutover.
- [ ] 8.4 Implement onboarding/recovery for distinct write App while preserving independent read connection and documented unsupported GHES state; verify full rerun/cancel UX and no silent token reuse.
- [ ] 8.5 Add shared-history corrupt JSON, unsupported schema and unsafe-path blocked cleanup; verify no broad file removal, persistent global error state and preservation of unrelated scopes.
- [ ] 8.6 Add explicit-consent whole-history purge flow and backup-copy accounting; verify denial leaves all bytes untouched and accepted deletion is restricted to safe app-owned paths.

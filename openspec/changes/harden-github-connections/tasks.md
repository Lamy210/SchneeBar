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

# GitHub integration hardening — reviewed implementation plan

Status: Proposed, 2026-11-06. Scope: SchneeBar GitHub access plus future credential-free SchneeRunner companion signals. This plan separates **confirmed code shape**, **risk inference**, and **required proof**. No real account or live token should be used in tests.

## Findings, evidence and acceptance

| ID | Verified source condition | Risk / unknown | Required response |
| --- | --- | --- | --- |
| SEC-001 | Keychain new-item add sets `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly` and `kSecAttrSynchronizable=false`; base query lacks `kSecUseDataProtectionKeychain` | Apple's macOS Data Protection Keychain selection may be needed for this accessibility class; actual storage and access behavior unverified | Real-Mac DPK test, legacy migration with replay-safe verify-before-delete |
| SEC-002 | Device Flow begin posts `client_id` only; decoding accepts non-expiring token response shape | New apps may issue long-lived credentials; *actual app configuration not checked* | Explicit expiring-token request/policy with GHES compatibility, migration and expiry tests |
| SEC-003 | Ephemeral URLSession disables cookies/cache but has no explicit redirect delegate | Whether redirects could carry sensitive parameters/headers to an unexpected origin requires negative tests | Per-request origin allowlist, reject redirects for secret-bearing requests, test redirects and URLs |
| SEC-004 | Capability evaluator checks `Actions: write` + repo write and UI requires confirmation | UI selection alone cannot reduce GitHub App token's granted permissions | Read-only default App; separate write authorization/credential boundary before optional mutations |
| SEC-005 | `disconnect` deletes local Keychain/profile; delivery-history delete uses `try?` | Local history deletion can fail silently; remote App authorization is distinct | Report local cleanup failures and link to GitHub revoke page; no false remote-revoked claim |
| SEC-006 | Preview accepts user-provided public GitHub App client ID | Unknown App publisher/permissions can induce user consent to a different App | Display App publisher/permissions when verifiable; warn and fail closed if identity is unverified for an owned default |
| SEC-007 | Runner uses DistributedNotificationCenter for local build/character events | Local event origin is not an authentication or write-authorization signal | Untrusted display-only typed adapter, bounded payload/TTL, no write-command bridge |
| SEC-008 | Stable release is gated on Apple signing/notarization; preview remains unsigned | A user could install a counterfeit/modified artifact without independent verification | Enforce provenance/signing gates; unsigned builds marked untrusted preview, never marketed stable |

## External primary references

- Apple macOS Data Protection Keychain: https://developer.apple.com/documentation/security/ksecusedataprotectionkeychain
- GitHub expiring user tokens: https://docs.github.com/en/apps/creating-github-apps/authenticating-with-a-github-app/refreshing-user-access-tokens
- GitHub App Device Flow: https://docs.github.com/en/apps/creating-github-apps/authenticating-with-a-github-app/authenticating-with-a-github-app-on-behalf-of-a-user
- RFC 8628 Device Authorization Grant: https://www.rfc-editor.org/rfc/rfc8628
- Existing project decision: [ADR-0002](decisions/0002-github-authentication-flow.md).
- Release gate: [SchneeBar release policy](RELEASE.md).

## Execution sequencing

**Step A: characterize (no behavior change).** Add fake Keychain abstraction and synthetic URLSession transport tests, inventory all `GitHubCredentialStore` callers and old service accounts, assert existing behavior. On a real signed macOS build inspect the actual storage/lock behavior before claiming exposure.

**Step B: DPK migration.** Add `kSecUseDataProtectionKeychain: true` consistently to DPK load/add/update/delete queries. For legacy access, use separate **legacy-only** queries; only allow migration for exact app service/account, never list unrelated Keychain items. Verify endpoint binding, authenticated numeric account and full roundtrip. Write + read new record before deleting legacy. On failure preserve legacy and avoid ambiguous dual credentials, report error. Existing `AfterFirstUnlock` is intended for background monitoring; `WhenUnlocked` for optional write-only credentials needs a separate usability test. Code-signing, team ID and access groups must be validated on a real app; an unsigned CI fixture is insufficient.

**Step C: expiry-aware issuance.** Request `offline_access` on owned GitHub.com/GHE.com apps where GitHub supports it; reject newly issued non-expiring responses under an explicit policy. Do not retroactively delete legacy credentials until account recovery/migration is prepared. For GHES, gate on server version and verified behavior, otherwise explicitly warn/disable rather than assuming hosted semantics. Preserve refresh single-flight and 401/SSO handling. Test refresh failure after successful rotation and recovery from expired refresh token.

**Step D: transport redirect policy.** Isolate authenticated API and OAuth token operations. Reject unexpected HTTP redirects (including same-host if unsupported), and test cross-origin, scheme downgrade, query/userinfo, nonstandard port, DNS host changes and mock response Location headers. Do not equate HTTPS alone with trust for user-supplied GHES; validate chosen origin and TLS normally. Authentication tokens must never appear in logs, crash reports or app event payloads.

**Step E: write boundary.** Read and write GitHub Apps/authorizations should be independently scoped; keep the mutating service callable only by explicit confirmed UI operation. Reevaluate permissions at the service boundary. Never permit a Character event, external-widget file or local notification to issue a workflow write.

**Step F: disconnect UX.** Separate locally removed / remote authorization not revoked / cleanup pending / failure states. Link directly to GitHub Applications settings when automated revocation is not possible. Never put a client secret into the macOS binary.

## Verification matrix

1. Existing Keychain entry → DPK record → relaunch successfully → old entry removal; failures leave old entry recoverable.
2. Locked machine/read-only monitoring and interactive write action behave according to documented accessibility class.
3. OAuth success/denial/timeout/slow_down/refresh rotation, non-expiring token and malformed expiry responses.
4. Cross-origin redirect with `Authorization` or OAuth body triggers **zero** secret-bearing requests to redirected origin.
5. Two concurrent refreshes cause exactly one rotation; account/host mismatch stops before network.
6. Read-only app credential attempts write → 0 mutation requests; confirmed write policy permits only chosen repository/run.
7. Disconnect cleanup error remains visible; no claim that remote authorization was revoked.
8. Malformed local event cannot reach GitHub mutation service.
9. Release artifact verification and secret/PII-safe diagnostics.

## Security decision boundary

ADR-0002 remains **Accepted**: local-first Device Flow and no mandatory auth broker. Switching to hosted authorization-code/PKCE is a **separate future decision** with backend threat model, secret custody, GHES compatibility, SLO/cost analysis. This proposal does not introduce a hosted backend.

Implementation to be tracked by `openspec/changes/harden-github-connections/`; do not mark SEC items complete before tests.

## Review closure (P0/P1, 2026-11-07)

The OpenSpec now defines three explicit implementation contracts; these are **unimplemented** and must be reviewed/tested before enabling GitHub-triggered integrations:

1. `openspec/changes/harden-github-connections/credential-lifecycle-contract.md` — per-identity epoch, durable state transitions, migration/refresh/disconnect fencing and reauthentication after provider-side rotation crash.
2. `openspec/changes/harden-github-connections/write-authorization-contract.md` — separate read/write App authorization, current server capability evidence and single-use user intent; existing broad read tokens do not authorize writes by default.
3. `openspec/changes/harden-github-connections/cleanup-ledger-contract.md` — profile-independent step journal, partial deletion retry and global UI state across restarts.

Acceptance requires synthetic race/crash/error injection and real-Mac signed Keychain tests. A passed OpenSpec CLI validation is **not** proof of these runtime guarantees.

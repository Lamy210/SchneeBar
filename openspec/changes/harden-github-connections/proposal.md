# Proposal: Harden SchneeBar's local-first GitHub connections

## Why

Existing GitHub account sessions, Keychain tokens and optional write actions form a security boundary that Companion integration must not weaken. Static review found missing protection verification and incomplete tests for token expiry, redirects, permission scope and disconnect cleanup. These are unverified exploit risks, not known compromises.

## What Changes

- Verify macOS Data Protection Keychain behavior and migrate legacy secrets without destructive first steps.
- Require expiry-aware issuance for verified supported GitHub App deployments; preserve safe legacy/enterprise recovery.
- Prohibit secret-bearing redirects to unauthorized origins.
- Require independent, explicit authorization for write operations and fail closed when capability is unknown; **strict cutover is an acknowledged breaking change** for users of legacy Workflow rerun/cancel until new write authorization is enrolled.
- Separate local disconnection, remaining GitHub authorization and incomplete cleanup states.
- Make onboarding and account recovery understandable without falsely asserting the GitHub App publisher or account security state.
- Prevent untrusted local/character events from triggering GitHub mutations.

## Capabilities

### New Capabilities

- `github-credential-security`: Secret storage, expiry, endpoint binding, permission enforcement, redirect protection and truthful disconnect semantics.
- `github-connection-security-ui`: User-facing account/App identity evidence, safe authorization flow, connection health and incident-recovery guidance.

### Modified Capabilities

- None. The existing GitHub implementation predates the OpenSpec canonical spec baseline; this is a behavioral hardening proposal, not proof that safeguards are currently absent everywhere.

## Impact

- `SchneeBarGitHubKeychain`, `SchneeBarGitHub`, `SchneeBarGitHubFeature`, GitHub runtime model, mock transports and security tests.
- GitHub.com, GHE.com and version-supported GHES require separate compatibility evidence.
- Preserve accepted ADR-0002: the default stays local-first GitHub App Device Flow; hosted Authorization Code + PKCE broker is out of scope without a new ADR.
- Tracking: issues #368/#369; integration depends on these gates before enabling GitHub-to-Companion events.

## Non-Goals

No mandatory backend, no Client Secret in the macOS app, no GitHub account password/2FA collection, no assertion of penetration-test completion and no unreviewed remote revocation automation.

## Validation / rollback

Test in synthetic OAuth/HTTP/Keychain fixtures plus a signed real Mac. Keep legacy credentials recoverable through partial failures. Feature-gate migrations and preserve reauthentication paths. Never equate deleting a local token with revoking a GitHub-side grant.

## Rollout compatibility and review blockers

Phase 0 (this PR) is specification-only and preserves the running product unchanged. A future strictWriteGrantV2 release must verify provisioned read/write GitHub Apps, host compatibility and reauthorization UI **before** its explicit approval. When strict policy is enabled, legacy read credentials must no longer perform writes, even if server-side permission exists; read monitoring continues. Users without verified write enrollment receive a clear temporarily unavailable mutation state. Rollback never silently restores broad-token writes.

Reconnections use immutable per-enrollment identifiers and distinct Keychain namespaces. Corrupt shared history remains blocked without cross-account data loss. Detailed contracts: `credential-lifecycle-contract.md`, `write-authorization-contract.md`, `cleanup-ledger-contract.md`.

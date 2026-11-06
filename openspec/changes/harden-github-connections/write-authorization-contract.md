# Contract: Explicit GitHub write authority

Status: Proposed; no actual second GitHub App is provisioned or configured by this document.

## Authorization model

A **read connection** has `purpose=read`, canonical provider origin, stable GitHub account ID and an associated GitHub App client ID. It is usable for activity reads regardless of whether the server-side token happens to contain broader privileges; app-local restriction is not a remote scope reduction.

An independent **write grant** has `purpose=write` plus `readConnectionID`, canonical origin, numeric account ID, **write GitHub App client ID**, authorized account association, repository identity and installation evidence when available. Its bearer/refresh credentials reside in distinct Keychain account namespace and never enter a widget/Companion domain. Actual App installation/permission evidence is obtained from authenticated provider results, not inferred from a client ID string. If App identity or evidence is unavailable, the write grant remains `unverified` and cannot authorize a mutation.

A write-capable token MUST NOT be automatically reused as the read credential and vice versa. Existing user-supplied GitHub Apps with `actions:write` remain readable but their workflow action control is gated off until an explicit write grant is enrolled and verified. No silent token cloning or account migration.

## One-shot authorization for each mutation

1. User starts from the current repository/run in the main SchneeBar UI; no local event/Companion callback can originate this action.
2. UI describes exact operation (`rerun` or `cancel`), host, repository, workflow run and account; explicit confirmation creates a short-lived, single-use intent tied to these IDs and current connection epoch (not to a string title).
3. At mutation service boundary, validate active write grant matches origin + account + App association + repository ID; verify current capability evidence proves Actions(write) and repository operation permissions. Evidence must be fresh for the operation; unknown/stale/ambiguous permission -> block. Validate user's confirmation intent is unused, unexpired and matches operation and run ID.
4. The client sends exactly one authorized request for that confirmation. A retry needs new user confirmation unless operation-specific safety and idempotence are proven.
5. Revoke/disable/reauthentication/disconnect invalidates outstanding intents and stops write work. Untrusted local input has no constructor or API reference for a write intent.

## Deployment matrix

- GitHub.com / GHE.com: distinct owner-approved read/write GitHub App registrations are the target design; account and installation evidence must be explicitly proven.
- GHES: separate app registration on target GHES; do not infer hosted App identity or permission support. Unsupported version -> writes disabled, read-only mode remains.
- Personal/fine-grained PAT: existing compatibility path may remain for reading, but MUST NOT implicitly satisfy new write-grant contract; any PAT write capability requires a separate reviewed threat model/spec.
- No Client Secret or GitHub App private key is bundled in the native executable, and ADR-0002 Device Flow remains accepted.

## Verification

A read token with Actions(write) but no verified separate write grant yields **zero mutation HTTP calls**. Conflicting account/clientID/installation/repository identifiers and stale confirmation intents all produce zero writes. A verified authorized user confirmation results only in a request for the exact selected run and action.

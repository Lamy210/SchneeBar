# Contract: Explicit GitHub write authority

Status: Proposed; no actual second GitHub App is provisioned or configured by this document.

## Authorization model

A **read connection** has `purpose=read`, immutable enrollmentID, canonical provider origin, stable GitHub account ID and an associated GitHub App client ID. It is usable for activity reads regardless of whether the server-side token happens to contain broader privileges; app-local restriction is not a remote scope reduction.

An independent **write grant** has `purpose=write`, its **own immutable enrollmentID** plus a reference to the current read enrollment (not just a reusable profile UUID), canonical origin, numeric account ID, **write GitHub App client ID**, authorized account association, repository identity and installation evidence when available. Its bearer/refresh credentials reside in distinct Keychain account namespace and never enter a widget/Companion domain. Actual App installation/permission evidence is obtained from authenticated provider results, not inferred from a client ID string. If App identity or evidence is unavailable, the write grant remains `unverified` and cannot authorize a mutation.

A write-capable token MUST NOT be automatically reused as the read credential and vice versa. **Once strictWriteGrantV2 policy is activated**, existing user-supplied GitHub Apps with `actions:write` remain readable but their workflow actions are disabled until an explicit write grant is enrolled and verified. The earlier released behavior is not silently modified by this Phase-0 documentation PR. No silent token cloning, account migration, or permission downgrade claim.

## One-shot authorization for each mutation

1. User starts from the current repository/run in the main SchneeBar UI; no local event/Companion callback can originate this action.
2. UI describes exact operation (`rerun` or `cancel`), host, repository, workflow run and account; explicit confirmation creates a short-lived, single-use intent tied to these IDs, **read/write enrollmentIDs**, and current connection epochs (not to a string title).
3. At mutation service boundary, validate active write grant matches origin + account + App association + repository ID; verify current capability evidence proves Actions(write) and repository operation permissions. Evidence must be fresh for the operation; unknown/stale/ambiguous permission -> block. Validate user's confirmation intent is unused, unexpired and matches operation and run ID.
4. The client sends exactly one authorized request for that confirmation. A retry needs new user confirmation unless operation-specific safety and idempotence are proven.
5. Revoke/disable/reauthentication/disconnect invalidates outstanding intents and stops write work. Untrusted local input has no constructor or API reference for a write intent.

## Deployment matrix

- GitHub.com / GHE.com: distinct owner-approved read/write GitHub App registrations are the target design; account and installation evidence must be explicitly proven.
- GHES: separate app registration on target GHES; do not infer hosted App identity or permission support. Unsupported version -> writes disabled, read-only mode remains.
- Personal/fine-grained PAT: existing compatibility path may remain for reading, but MUST NOT implicitly satisfy new write-grant contract; any PAT write capability requires a separate reviewed threat model/spec.
- No Client Secret or GitHub App private key is bundled in the native executable, and ADR-0002 Device Flow remains accepted.

## Verification

Under strictWriteGrantV2, a read token with Actions(write) but no verified separate write grant yields **zero mutation HTTP calls**. Conflicting account/clientID/installation/repository identifiers and stale confirmation intents all produce zero writes. A verified authorized user confirmation results only in a request for the exact selected run and action.

## Staged rollout, UX and compatibility decision (breaking change)

**Behavioral impact:** migrating to strictWriteGrantV2 deliberately removes the previous implicit `Actions:write` workflow rerun/cancel pathway. This is a **user-visible breaking change** for customers who have not enrolled a separate verified write App. The `integrate-schneerunner` proposal's “preserve developer features” means preserve read-only developer monitoring and user-facing UI; it cannot promise uninterrupted workflow mutation without the new authorization. An independently enrolled write App MUST be provisioned/configured and tested before enabling the strict policy for an affected host.

Rollout stages and gates:

| Stage | Existing workflow writes | Required proof / UI |
| --- | --- | --- |
| `docsOnly` (this PR) | Existing shipping binary unchanged | Contracts and tests defined; **no** runtime policy switch |
| `enrollmentPreview` (future separate code PR) | Existing shipping policy unchanged; new V2 grants do not automatically authorize writes | Maintainer-approved read/write App registration, Device Flow host/account binding, simulated capability test, optional enrollment UX |
| `strictV2` (separate explicitly approved release decision) | Only verified new write grant can mutate; otherwise write actions are visibly unavailable | Clear in-app explanation before cutover, recovery entry point, account/repository write-grant setup, GHES capability matrix, review/rollback evidence |
| `strictV2Rollback` | Preserve strict fail-closed write policy or disable workflow writes; **never** silently restore broad-token mutation | Existing read-only activity, local Companion/Focus and accounts keep working; explicit operator/user communication |

There is **no hidden legacy write fallback inside strictV2**. For unsupported GHES or an unprovisioned write App, read-only developer activity remains usable but rerun/cancel is intentionally unavailable, with no fake “reconnect fixes this” promise. A future deliberate decision to restore legacy write functionality requires a separately approved ADR and security review; installing an older binary is outside an automatically safe rollback guarantee.

Release gate: maintainer records affected-provider compatibility results and shows the user the distinction between **current broad authorization**, **new separate write authorization**, and **temporarily disabled write actions**; no silent policy flip. Account migration retains original read connection and never copies its token to a write namespace.

### Acceptance cases

- Under `docsOnly` / prior shipping binary the current workflow behavior is unaffected by documentation changes.
- Under `strictV2`, a previously write-capable read App without enrolled V2 write grant displays a clear unavailable/authorization-required state and produces zero mutation HTTP calls; reads continue.
- Enrolled V2 write grant on the same canonical origin/account/repo and current epoch allows user-confirmed write for only the selected run.
- Unsupported GHES/unknown App identity shows capability limitation rather than silently using legacy token; user retains read-only connections and can inspect the compatibility explanation.
- Rollback/feature disable never reuses an old broad-scope read token for a workflow mutation without a separate reviewed security decision.

# Development Plan

## Phase 0 — Foundation ✅

Completed in the bootstrap work:

- Native AppKit `NSStatusItem` shell
- SwiftUI popover
- Core / DesignSystem / feature boundaries
- deterministic fixture scenarios
- local Visual Harness
- CI-rendered visual report
- Swift Testing
- CodeQL / Dependabot / public-repo security policy

## Phase 1 — Widget Engine ✅

The widget engine foundation is complete enough to build product features on top of it.

Implemented:

- provider-neutral `WidgetProvider` contract
- widget descriptors and snapshots
- representation variants (`compact` / `normal` / `critical`)
- severity and priority ordering
- smart visibility policies
- interval/adaptive refresh policies
- refresh-due scheduling with last-known-good fallback
- native Clock widget provider
- native CPU widget provider using macOS host CPU counters
- Developer Activity mapped into the same widget contract
- Observation-backed runtime model
- Menu Bar rendering from visible widget snapshots
- shared Widget Feature UI
- deterministic Widget Visual Regression scenarios
- widget ordering, enable/disable, and representation preferences
- persisted widget configuration
- provider-neutral runtime diagnostics and stale/failed provider health state
- race-safe provider replacement and overlapping refresh handling
- macOS sleep/wake lifecycle handling with stale async-work rejection

Deferred intentionally:

- additional system widgets until Developer Activity and the runtime contract have more real-world usage

## Phase 2 — GitHub connection foundation 🚧

Implemented foundation:

- Keychain-backed credential storage
- `GitHubConnection` and persistent connection profile models
- Device Flow for local-first GitHub.com authentication
- session coordination
- repository access and monitored-repository selection
- endpoint resolution without hard-coding `api.github.com`
- GHES endpoint discovery foundation
- discovered GHES version compatibility surfaced in connection health without masking operational failures
- bounded GHES metadata rediscovery during existing refreshes, capped at one `/meta` request when the persisted 24-hour check-attempt cadence is due, persisting failed attempts to prevent refresh-time polling, with no background polling and best-effort fallback to the last known server version
- REST API version policy
- centralized REST API request-version selection across GitHub clients, including explicit overrides and evidence-backed GHES 3.20-3.22 release mapping without guessing untested releases
- GitHub.com / enterprise-aware request construction boundaries
- session-scoped, repository-aware capability assessment for Actions, Pull Requests, Checks, and Deployments
- conservative public-repository and untested/unknown-GHES capability evidence handling
- fresh capability recomputation from access inventory on session establish/restore, with App-local normalized assessment caching
- Actions polling preflight that blocks only definitive capability unavailability while keeping unknown/missing evidence requestable
- separate attempted/blocked Activity accounting so capability blocks do not consume the network polling budget
- Actions / Reviews / Checks / Deployments availability surfaced independently in repository management
- same-endpoint/same-account reconnect reconciliation that preserves connection identity, repository selection, monitoring state, and original creation time
- same-endpoint/different-account coexistence with connection-scoped credential isolation
- deterministic connection ordering for stable multi-account UI and polling behavior
- dedicated existing-connection Device Flow reauthentication
- same-account binding enforcement during recovery
- validate-before-Keychain replacement semantics
- stale refresh / recovery race protection
- evidence-backed SSO-required installation/connection health from explicit GitHub failure signals only; no inference from empty or forbidden resource sets

Remaining:

- broader enterprise connection validation before Phase 5

## Phase 3 — Developer Activity 🚧

Implemented:

- GitHub Actions workflow runs
- workflow jobs and normalized job summaries
- lazy job-detail loading
- monitored repository management
- provider destinations for opening GitHub activity
- Pull Request metadata loading
- Developer Activity integration into the widget engine
- direct GitHub review-request activity using stable connected-account IDs
- bounded Check Run activity for review/workflow-derived SHAs
- hidden successful Workflow evidence for Check candidate discovery
- provider-neutral priority Inbox semantics across Reviews, Checks, and Workflows
- fixed source-list request budgets across Workflow / Review / Check polling
- Actions / Reviews / Checks capability presentation
- source-level activity failure/accounting with capability-only connection-health separation
- repository-selection and reset isolation across all activity source caches
- kind-aware popover behavior where only Workflow rows expose local job detail
- deterministic mixed Inbox, review-only, and mixed capability Visual Regression fixtures
- conservative matrix-like workflow job aggregation using high-confidence name grouping without inferring matrix keys
- provider-neutral nested activity detail rows with one-level disclosure presentation
- raw workflow-job summary preservation while grouped presentation rows retain original job URLs and failure details
- deterministic matrix success/failure Visual Regression fixtures
- PR-scoped conservative superseded-run handling that removes older different-SHA runs from both Workflow Inbox activity and Workflow-derived Check evidence

Next:

- additional real-world validation of bounded polling and enterprise capability edge cases

Deferred intentionally:

- branch/push supersession when a single Pull Request identity is unavailable
- re-run-attempt-specific history or replacement UX

## Phase 4 — Delivery Timeline 🚧

Implemented:

- workflow execution correlation
- safe run-to-run correlation
- merged Pull Request correlation
- current GitHub REST API compatible commit → associated Pull Request evidence
- conservative rejection of stale, mismatched, or ambiguous evidence
- demand-driven Delivery evidence loading only when Workflow detail is opened
- bounded correlation evidence requests with exact-run, Pull Request, base-branch run, and commit-association limits
- first user-visible PR → merge → base-branch execution timeline inside Workflow detail
- confidence-aware correlated, evidence-unavailable, and temporarily-unavailable states
- best-effort timeline composition that preserves successfully loaded Workflow Jobs
- deterministic Light/Dark Delivery Timeline visual fixtures, including matrix-job detail
- exact-SHA GitHub Deployment loading after proven base-execution correlation
- bounded Deployment enrichment with one deployment-list request and at most three latest-status requests
- full explicit-detail Delivery request ceiling verified at 12 HTTP requests
- provider-neutral Deployment timeline events with success/running/waiting/failure/neutral state mapping
- Deployment capability gating that skips definitive unavailability while keeping unknown evidence explicitly requestable
- best-effort Deployment enrichment that preserves Jobs and the existing PR → merge → execution timeline on absence or technical failure
- deterministic Light/Dark Deployment Timeline fixtures for production success, staging running, no evidence, unavailable capability, and the three-deployment bound
- demand-driven repository Environment enrichment for already-correlated exact-SHA Deployments
- built-in Environment protection summaries for reviewer count, wait timer, self-review prevention, and branch-policy mode
- one-request Environment enrichment cap with a complete explicit-detail Delivery ceiling of 12 feature HTTP requests
- conservative page-1 Environment matching that preserves existing Deployment events on truncation, absence, ambiguity, or technical failure
- Actions-capability-gated Environment detail loading with no background Environment polling
- reviewer-identity and provider-Environment-URL minimization at normalization boundaries
- deterministic Light/Dark Environment protection and fallback fixtures
- zero-request GitHub repository default-branch discovery from existing access inventory
- authoritative Activity-detail repository resolution from runtime inventory instead of UI-model reconstruction
- exact, case-sensitive default-branch presentation that keeps non-default Pull Request targets fully correlatable
- deterministic Light/Dark proven-default and proven-non-default Delivery Timeline fixtures
- repository-scoped standalone Delivery history reachable from loaded Workflow detail
- one-request completed Workflow history loading capped at 20 rows
- zero-request Back navigation that preserves the loaded Workflow detail
- deterministic Light/Dark Delivery history fixtures for mixed branches, neutral completions, empty history, and request failure
- provider-neutral Delivery evidence explanations for exact correlation, missing evidence, and technical unavailability
- deterministic evidence checklists with raw-SHA minimization and zero additional network requests
- Deployment exact-commit-match explanation without changing best-effort enrichment semantics
- expandable Light/Dark Delivery evidence presentation inside Activity detail
- zero-request PR-scoped Workflow failure → success recovery detection from existing polling evidence
- replay-safe ephemeral recovery events that survive transient polling failures but reset on monitoring removal/connection reset
- privacy-minimized macOS local recovery notifications using provisional authorization and current notification settings
- generic system notification copy with no repository, account, branch, Pull Request, workflow, or URL disclosure
- bounded persisted Delivery history in versioned Application Support JSON with atomic writes
- deterministic live + cached Delivery history merging up to 200 entries per repository scope
- cached Delivery history fallback for transient GitHub failure or definitive current Actions unavailability
- source-scoped persisted history cleanup on explicit connection disconnect
- zero additional GitHub requests: live standalone history remains exactly one completed-runs request

Next:

- revisit standalone/paginated Environment browsing, local history-row drill-down, and custom protection-rule details only if product usage justifies the extra scope

## Phase 5 — Enterprise

Foundation already available from earlier phases:

- provider-specific endpoint resolution behind adapters
- GHES discovery primitives
- REST API version policy
- connection profiles that do not assume GitHub.com-only hosts
- pre-auth endpoint validation and canonicalization for GitHub.com, GHE.com, and GHES
- deployment-specific onboarding guidance and safe default transitions for GitHub.com, GHE.com, and GHES
- GHES onboarding preflight progress that distinguishes server discovery from the later Device Flow authorization request
- explicit GHES preflight review with discovered host/version compatibility before Device Flow authorization
- centralized transient network-failure classification shared by session refresh and activity loading
- GHES discovery errors that distinguish offline/DNS/connectivity/timeout/interruption failures without masking TLS or protocol failures
- GHES onboarding/recovery guidance that suggests VPN/private-network checks only for enterprise-server connectivity failures
- evidence-backed partial SAML/SSO connection status when accessible installations coexist with explicit SSO-required failures

Still required:

- GitHub Enterprise Cloud / SAML / EMU states
- GHES capability/API-version negotiation

## Phase 6 — Interaction and extensibility

- opt-in workflow re-run/cancel actions
- provider/plugin contracts
- declarative external widgets
- additional CI providers after GitHub architecture proves stable

## Current implementation priority

1. Broaden enterprise validation toward Phase 5 requirements.
2. Revisit standalone/paginated Environment browsing, local history-row drill-down, and custom protection-rule details only if product usage justifies the extra scope.
3. Only then broaden system widgets or external provider/plugin scope.

## Engineering constraints

- Domain/Application code must remain independent of SwiftUI and AppKit.
- Provider DTOs must be normalized before they reach generic UI state.
- Provider-specific behavior stays behind port/adapter boundaries.
- Prefer Swift Concurrency (`async`/`await`, actors, `AsyncSequence`) over callback/GCD abstractions.
- UI-visible states should have deterministic fixtures where practical for Visual CI.
- Secrets, tokens, private enterprise URLs, and private repository data must never be committed.

## Non-goals for early phases

- GitHub client replacement
- repository administration
- mandatory cloud backend
- arbitrary native plugin loading
- full Bartender/Ice clone
- release signing secrets in PR CI

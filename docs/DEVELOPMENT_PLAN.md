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
- REST API version policy
- GitHub.com / enterprise-aware request construction boundaries
- session-scoped, repository-aware capability assessment for Actions, Pull Requests, Checks, and Deployments
- conservative public-repository and untested/unknown-GHES capability evidence handling
- fresh capability recomputation from access inventory on session establish/restore, with App-local normalized assessment caching
- Actions polling preflight that blocks only definitive capability unavailability while keeping unknown/missing evidence requestable
- separate attempted/blocked Activity accounting so capability blocks do not consume the network polling budget
- Actions / Reviews / Checks availability surfaced independently in repository management
- same-endpoint/same-account reconnect reconciliation that preserves connection identity, repository selection, monitoring state, and original creation time
- same-endpoint/different-account coexistence with connection-scoped credential isolation
- deterministic connection ordering for stable multi-account UI and polling behavior
- dedicated existing-connection Device Flow reauthentication
- same-account binding enforcement during recovery
- validate-before-Keychain replacement semantics
- stale refresh / recovery race protection

Remaining:

- broader enterprise connection validation before Phase 5
- extend capability presentation to deployments as that product surface lands

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

Next:

- superseded-run handling in the user-facing model
- additional real-world validation of bounded polling and enterprise capability edge cases

## Phase 4 — Delivery Timeline 🚧

Implemented correlation primitives:

- workflow execution correlation
- safe run-to-run correlation
- merged Pull Request correlation
- current GitHub REST API compatible commit → associated Pull Request evidence
- conservative rejection of stale, mismatched, or ambiguous evidence

Next:

- surface correlation evidence in the user-facing delivery timeline
- PR → merge → default-branch execution timeline presentation
- deployments / environments
- confidence-aware correlation states
- recovery notifications

## Phase 5 — Enterprise

Foundation already available from earlier phases:

- provider-specific endpoint resolution behind adapters
- GHES discovery primitives
- REST API version policy
- connection profiles that do not assume GitHub.com-only hosts

Still required:

- GitHub Enterprise Cloud / SAML / EMU states
- GHE.com product UX and validation
- self-hosted GHES connection wizard
- GHES capability/API-version negotiation
- VPN/private-network-aware error states

## Phase 6 — Interaction and extensibility

- opt-in workflow re-run/cancel actions
- provider/plugin contracts
- declarative external widgets
- additional CI providers after GitHub architecture proves stable

## Current implementation priority

1. Harden Phase 3 with superseded-run handling.
2. Integrate existing correlation primitives into the Phase 4 delivery timeline.
3. Add deployments/environments and recovery states.
4. Broaden enterprise validation toward Phase 5 requirements.
5. Only then broaden system widgets or external provider/plugin scope.

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

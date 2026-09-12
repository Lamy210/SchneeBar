# Development Plan

## Phase 0 — Foundation (completed in bootstrap PR)

- Native AppKit `NSStatusItem` shell
- SwiftUI popover
- Core / DesignSystem / feature boundaries
- deterministic fixture scenarios
- local Visual Harness
- CI-rendered visual report
- Swift Testing
- CodeQL / Dependabot / public-repo security policy

## Phase 1 — Widget Engine (current)

Implemented in the current branch:

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

Remaining before Phase 1 is considered complete:

- settings for widget ordering, enable/disable, and representation preference
- persistence for widget configuration
- wake/sleep refresh handling
- runtime diagnostics for provider failures/stale snapshots
- additional system widgets only after the engine contract proves stable

## Phase 2 — GitHub connection foundation

- Keychain credential storage
- GitHubConnection model
- Device Flow for local-first GitHub.com auth
- installation/repository selection
- endpoint and capability negotiation
- multi-account support

## Phase 3 — Developer Activity

- Actions workflow runs/jobs
- Pull Requests / review requests
- Checks
- priority-based Inbox
- matrix aggregation
- superseded-run handling

## Phase 4 — Delivery Timeline

- PR → merge → main correlation
- Deployments/environments
- confidence-aware correlation
- recovery notifications

## Phase 5 — Enterprise

- GitHub Enterprise Cloud / SAML / EMU states
- GHE.com endpoint support
- self-hosted GHES connection wizard
- GHES capability/API-version negotiation
- VPN/private-network-aware error states

## Phase 6 — Interaction and extensibility

- opt-in workflow re-run/cancel actions
- provider/plugin contracts
- declarative external widgets
- additional CI providers after GitHub architecture proves stable

## Non-goals for early phases

- GitHub client replacement
- repository administration
- mandatory cloud backend
- arbitrary native plugin loading
- full Bartender/Ice clone
- release signing secrets in PR CI

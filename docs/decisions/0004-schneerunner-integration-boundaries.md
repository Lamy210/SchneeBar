# ADR-0004: Integrate SchneeRunner capabilities into SchneeBar incrementally

- Status: Proposed
- Date: 2026-11-06
- Scope: SchneeBar / SchneeRunner product integration

## Context

SchneeBar already has a Tuist-based Swift 6 modular-monolith app, SwiftUI/AppKit menu-bar UI, widget engine, GitHub.com/GHE.com/GHES connections, and an established Design System. SchneeRunner is a SwiftPM macOS 14+ local-first application with reusable animation/character-pack and productivity domain logic, plus its own AppKit lifecycle, status item, CPU polling, notification scheduling, login-item registration and local event listeners.

A direct copy of both application lifecycles would duplicate `NSStatusItem`, launch-at-login ownership, CPU sampling, persistent preferences and notifications. Authentication also introduces privileged operations that must not become reachable through local character events.

Existing authoritative decisions remain in effect: ADR-0001 (native modular architecture) and ADR-0002 (local-first GitHub App Device Flow). This ADR does not silently replace the accepted authentication approach with a mandatory cloud broker.

## Decision

1. SchneeBar is the target app, product identity, UI system and composition root, with a **single** macOS lifecycle, `NSStatusItem`, login-item owner, and notification coordinator.
2. Keep the SchneeBar Tuist project and macOS 15+ deployment target for the initial integration; no simultaneous macOS 14 support promise.
3. Port/reuse **domain and asset-processing behavior** from SchneeRunnerCore behind dedicated ports/modules first. Avoid moving SchneeRunner's `AppDelegate`, `StatusMenuController`, and global-state setup wholesale.
4. Keep SchneeBar's existing GitHub connection/session/keychain infrastructure as the **only privileged GitHub credential/API boundary**. The companion domain receives bounded, credential-free activity signals only.
5. A shared system metrics service owns host CPU sampling; adapters feed the widget and animation policy. Report host utilization separately from Activity Monitor per-process `% CPU`, and distinguish raw and smoothed metrics.
6. A unified productivity scheduler owns timer/Pomodoro/reminder reconciliation and system-notification identifiers; it restores deadline-authoritative state after restart or sleep and never double-delivers events.
7. User-controlled Companion, Productivity, System and Developer capabilities are individually switchable; hidden/disabled animation must suspend its frame scheduling and asset work.
8. Keep SchneeRunner distributed and maintainable until functional parity, safe data migration, and release gates are demonstrated. Do not archive or redirect the original app at Phase 0.
9. Track credential hardening independently in the `harden-github-connections` OpenSpec change. ADR-0002 must only be revisited via a new, explicit decision.
10. Treat character artwork, source code reuse, localization and release assets as separate license/provenance decisions. No non-authorized copyrighted imagery bundled into the new stable distribution.

## Alternatives

- One-shot code merge: rejected; high risk to lifecycle, persistence and permission boundaries.
- Two permanently running apps with IPC: rejected as target; duplicates background work and adds event/auth attack surfaces. Allowed only as a short-lived migration diagnostic with no secrets.
- Incremental core reuse into one app: chosen.

## Architectural guardrails

```text
SchneeBar.app (SwiftUI/AppKit, one NSStatusItem)
  |-- Dashboard/Widget / Developer Activity / Focus / Companion feature views
  |-- Integration composition + Settings
  +-- Shared services: metrics, event projection, notification scheduler, migration
       |-- SchneeBar GitHub connection/session/credential service (privileged)
       |-- Companion core (no GitHub token/network or write-command capability)
       |-- Productivity core (no GitHub token/network)
       +-- macOS adapters (Keychain, notifications, storage, rendering)
```

Events entering Companion are **data**, not instructions. Local distributed notifications and external widgets are untrusted, validated, bounded and forbidden from invoking workflow mutations.

## Release and migration gates

- Unit tests for domain preservation, malicious assets and priority/TTL policies.
- Keychain/endpoint/token security findings resolved before enabling new GitHub-triggered features.
- Single-owner metrics/lifecycle/notification tests.
- Old app data stays intact until new state is written, validated and reloaded. Migration is idempotent, versioned, and reversible.
- UI visual regression, CPU/memory/wakeups measurement on the same device/configuration.
- No stable publication without existing SchneeBar release security and provenance requirements, including signing and notarization.
- Uncertain macOS behavior must be validated on a real machine before accepting this ADR.

## Consequences and revisit criteria

Positive: one UX, lower duplicate background work, reusable core contracts, credential isolation and gradual rollout. Costs: adapter work, macOS 14 migration gap, dual-app coexistence while transitioning.

Revisit if measured idle-resource regression is unacceptable, required macOS 14 support emerges, or a required companion feature cannot satisfy sandbox/signing constraints without a separately designed helper.

Related: `docs/SCHNEERUNNER_INTEGRATION.md`, `openspec/changes/integrate-schneerunner/`, `openspec/changes/harden-github-connections/`.

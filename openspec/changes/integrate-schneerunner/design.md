# Design: One app, optional character and productivity modules

## Context

SchneeBar is the target Tuist/macOS 15+ app (ADR-0001). SchneeRunner uses SwiftPM, has its own `AppDelegate` / `NSStatusItem`, event listeners, CPU monitor and `UNUserNotificationCenter` scheduler. Runtime state must not be owned twice.

## Architecture

```text
SchneeBar.app / composition root (one AppKit NSStatusItem)
  ├─ Home/Developer Activity (existing)
  ├─ Focus feature (new SwiftUI, DesignSystem)
  ├─ Companion feature (new SwiftUI + optional desktop AppKit renderer)
  ├─ Connection/Security views (existing + future hardening)
  └─ Shared services
       ├─ MetricsProvider → Widget + Animation policy
       ├─ NotificationCoordinator → Productivity scheduler
       ├─ GitHubActivitySignalProjector (credential-free)
       ├─ CompanionCore (animation/pack/trigger policy)
       ├─ ProductivityCore (deadline/recurrence state)
       └─ MigrationCoordinator → local state, never GitHub credentials
GitHub session + Keychain remain SchneeBarGitHub-only.
```

Prefer extracting SwiftPM-compatible pure domain source into separately tested targets added through Tuist; do not accidentally import RunnerApp as the SchneeBar composition root. Avoid requiring the runner executable or installed Runner app at runtime.

## Data boundaries

- `HostCPUUsageSample` has capture timestamp, counter provenance and 0–100 host percentage; a smoothed value is explicitly labeled. The existing CPU widget defines the display semantics. Activity Monitor process `% CPU` is not comparable without normalization.
- `DeveloperActivitySignal` contains source connection ID, stable repository ID, kind (`workflowSucceeded`, `workflowFailed`, `reviewRequested`, `deploymentChanged`), observed time, severity and bounded display-safe context. It must contain **no** bearer credential, arbitrary URL, command string or mutable GitHub API client.
- `CharacterTrigger` has source, priority, TTL, generation and cooldown; inputs from distributed notifications never gain trust merely by being local.
- Productivity snapshot is versioned and deadline-authoritative; schedule IDs are namespaced to the new application. Notification delivery is projection from persisted state, not authority.
- Migrate by validated snapshots and staged ownership; original Runner state never overwritten.

## Ordering and ownership

1. App initialization and storage load; keychain state remains within GitHub module.
2. Reconcile productivity state **before** scheduling/delivering notifications.
3. Start common metrics only when needed; consumers subscribe to one owner.
4. Start optional companion renderer only when enabled.
5. Only after credential hardening, project GitHub read-only activity into character signals.
6. Suspend CPU/animation frame scheduling when hidden and stop upon shutdown/sleep.

No direct calls from Companion to GitHub mutation services. Workflow rerun/cancel remains an explicitly confirmed feature action subject to GitHub capability checks.

## UI/UX

Use existing SchneeBar typography/material/spacing and visual harness. Home / Dev / Focus / Character / Connections are feature surfaces, not new floating top-level menu bars. Companion is opt-in; desktop window, click-through and autonomous movement each have independent preferences. Handle accessibility (VoiceOver, reduced motion, keyboard focus), Japanese and English labels and disconnection states. Keep existing quick-glance use efficient.

## Data migration

Copy-only opt-in migration from `Application Support/SchneeRunner`: validate regular files, canonical owned paths, resource budgets, schema versions, recurrence rules and package assets. Stage write; reload; commit; record migration marker. Old app state/notifications untouched until user explicitly authorizes cutover; schedule only one app's reminders. Failures preserve original and expose retry. Test both unsigned-preview and signed-app runtime differences.

## Security, performance and observability

Security concerns in `harden-github-connections` run separately. Treat imported images/pack files as untrusted and retain limits; do not bundle copyrighted fan imagery pending provenance review. Logs never include secrets, full file paths or private repository payloads by default.

Collect event/CPU sampling counts, UI frame budget, app idle CPU/wakeups, memory, notification reconciliation and GitHub rate-limit/401 counts. All diagnostics bounded, no raw token logging. Initial tentative idle goal <=1% with companion off; measure and revise based on baseline.

## Alternatives rejected

One-shot app merge (lifecycle duplication and unreviewed data moves); permanent IPC companion (second executable, duplicate notifications and new trust surface).

## Rollback

Each module behind a feature flag, disabled by default initially. Migration does not destroy old app data. Revert new modules without changing `SchneeBarGitHub` persisted credentials. Avoid changing bundle ID or Keychain service in the integration PR.

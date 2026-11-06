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

Copy-only opt-in migration from Runner-owned Application Support **and explicitly inventoried UserDefaults domains**: validate accessible per-bundle preference keys, regular files, canonical owned paths, resource budgets, schema versions, recurrence rules and package assets. When cross-app preferences are inaccessible, require an explicit Runner export or user-selected source; do not assume the new app's defaults see the old ones. Stage write; reload; commit; record migration marker. Old app state/notifications untouched until user explicitly authorizes cutover; schedule only one app's reminders. Failures preserve original and expose retry. Test both unsigned-preview and signed-app runtime differences.

## Security, performance and observability

Security concerns in `harden-github-connections` run separately. Treat imported images/pack files as untrusted and retain limits; do not bundle copyrighted fan imagery pending provenance review. Logs never include secrets, full file paths or private repository payloads by default.

Collect event/CPU sampling counts, UI frame budget, app idle CPU/wakeups, memory, notification reconciliation and GitHub rate-limit/401 counts. All diagnostics bounded, no raw token logging. Initial tentative idle goal <=1% with companion off; measure and revise based on baseline.

## Alternatives rejected

One-shot app merge (lifecycle duplication and unreviewed data moves); permanent IPC companion (second executable, duplicate notifications and new trust surface).

## Rollback

Each module behind a feature flag, disabled by default initially. Migration does not destroy old app data. Revert new modules without changing `SchneeBarGitHub` persisted credentials. Avoid changing bundle ID or Keychain service in the integration PR.

## Decisions and evidence gates

| Decision | Rationale | Counterexample / rejection criterion |
| --- | --- | --- |
| Reuse RunnerCore behavior in SchneeBar targets | Keeps one process and predictable UI | Dependency/licensing review rejects copying or runtime costs regress |
| Preserve current Device Flow ADR-0002 | No mandatory authentication server | New authoritative GitHub App requirement makes this untenable; open a separate ADR |
| Expose Companion only as credential-free consumer | Prevents local events reaching mutating GitHub API | A new feature requires explicit user-initiated action and a separate capability review |
| Copy-only migration first | Source data survives release rollback | Real users require live two-way sync; separately threat-model before considering it |

## Contracts and error-handling details

**Metrics**: use monotonic sample generation and host CPU counters; represent absent/invalid sample explicitly. Widget may consume raw CPU percentage and Companion may consume smoothing, but neither presents process CPU equivalence. Disabled consumer removes its subscription and stops work when none remain.

**Activity event**: typed allowlist of event kinds, source connection UUID, stable repository ID, observed timestamp, generation and bounded severity/context. Cache dedup key uses connection + repository + event/run ID + state, not raw UI text. Drop expired, too-old and inactive-generation events. No token, raw source URL, runner executable command or mutation callback.

**Notifications**: namespace IDs to SchneeBar bundle identity and migration source. Because one app cannot cancel another app's pending requests, **the first integrated release always imports Runner notification-bearing items as inactive data**. A trusted Runner stop/disable acknowledgement is not currently implemented or approved; do not enable imported notifications even on user-confirmed quit. Future cutover needs a separately accepted authenticated and replay-resistant protocol. Reconcile persisted deadline/recurrence state before installing any new request. A repeated startup must not emit duplicate completion.

**Asset and data migration**: staging directory must not follow symlinks or accept path traversal; validate copy and fully reload before atomic swap. Inventory both Application Support files and separate Runner UserDefaults domain; explicit user export fallback when cross-app access is unavailable. Retry tracks migration version/source provenance and old→new IDs, never deletes original, and exposes partial success. Persist pending-cutover state separately from committed data.

## Risks / Trade-offs

- User's Mac supports only macOS 14 → retain SchneeRunner; target does not promise backwards compatibility.
- Unsigned preview cannot deliver some notification behaviors → explicitly communicate capability state and test signed build.
- Third-party fan artwork rights uncertain → no bundled redistribution before permission/license review; generic default placeholder.
- Duplicate running apps → a click alone is not verification: require durable source disable acknowledgement or hold migrated reminders inactive; do not access the other app's notification center.
- Shared sampler semantic regression → preserve original CPU widget test fixtures and profile across fan-out.
- Performance regression → optional flags, real-device profiling, rollback modules independently.

## Migration Plan

1. Record baseline and artifact provenance; independently review ADR-0004.
2. Land focused security prerequisite and pure Core tests in separate PRs.
3. Introduce disabled-by-default feature flags with no persistent format migration.
4. Add copy-only staged import, opt-in notification ownership and diagnostic markers.
5. Perform real-device regression, migration/retry and dual-app tests before enabling new defaults.
6. On failure disable feature flags, roll back the SchneeBar change and keep Runner source state and previous GitHub credentials untouched.

## Review closure: executable contracts

- [Runner data & preference migration](runner-data-migration-contract.md): separately inventories Application Support + UserDefaults/bundle domain and guarantees copy-only atomic/idempotent promotion, partial import reporting and verified old→new UUID mapping.
- [Notification handoff](notification-handoff-contract.md): initial release supports `notImported → copiedInactive → handoffUnavailable` **data-only**; `awaitingRunnerStop → runnerDisabledVerified → barActive` is reserved for a separately approved, trust-verified future implementation. No automatic cross-app notification cancellation.
- [Local events, renderer and reminder calendar](local-events-and-time-contract.md): pre-decode 4 KiB byte limit, rate/channel/TTL caps, recoverable renderer errors rather than impossible process-crash survival, and Runner-compatible floating local-time DST policy.

**Evidence status:** contracts are proposed; source-app handoff support and complete preference-domain inventory are not yet implemented. The new application's Source→Destination `Application Support` and UserDefaults migrations must pass real-macOS compatibility and sandbox tests before opt-in activation.

**Local-event overload policy**: 12 set/update + 4 reserved clear/cancel accepted events in one rolling second, 128 pre-decode ingress attempts, 64 active local channels. A saturated terminal reserve or total ingress storm **clears untrusted volatile Companion reactions and quarantines the source**, not arbitrary application-owned timers, credentials or GitHub state. See [local events/time](local-events-and-time-contract.md).

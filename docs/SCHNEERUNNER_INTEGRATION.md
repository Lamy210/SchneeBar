# SchneeRunner → SchneeBar integration baseline (2026-11-06)

This document is the working product/integration baseline, not a claim that the integration already exists. Main repository: `Lamy210/SchneeBar`. Source capability repository: `Lamy210/SchneeRunner`.

## Objective and constraints

Deliver a single native macOS menu-bar app retaining SchneeBar visual identity while gaining optional SchneeRunner character and productivity capabilities. Keep GitHub connections and user data safe. Initially target macOS 15+; no mandatory auth backend; no unreviewed stable release.

Verified baseline in main:
- SchneeBar: Tuist, Swift 6, `SchneeBarCore`, `SchneeBarDesignSystem`, provider-neutral widgets/activity, GitHub session/inventory/capabilities, Keychain, single AppKit status item, visual harness.
- SchneeRunner: SwiftPM `SchneeRunnerCore`, renderers, `.schneerunner` pack import/export, animated image formats, deadline-derived timers/Pomodoro/reminders, desktop character, build and local state event listeners, separate `NSStatusItem`.
- Existing SchneeBar ADR-0002 **already accepts** Device Flow with explicit anti-phishing UX; do not represent a mandatory token broker as an approved change.
- SchneeBar currently has **no accepted project distribution license** according to README; code/artwork transfer and release provenance need a dedicated maintainer decision.

## Capability transition matrix

| Capability | Source of truth | Integration target | Gate |
| --- | --- | --- | --- |
| Menu bar, popover, settings, widgets | SchneeBar App/Core/DesignSystem | Preserve current lifecycle | Visual/perf regression |
| GitHub connections, account switching, GHE.com/GHES | SchneeBarGitHub + Keychain | Preserve privileged boundary | Security change first |
| Workflow rerun/cancel | SchneeBar mutation service | Explicit, capability-checked UI only | No event-triggered writes |
| Character animation policy, state precedence, clips | SchneeRunnerCore | CompanionCore adapter | Original tests ported |
| PNG/GIF/APNG/WebP/sprites/sequence/pack handling | SchneeRunnerCore | Safe asset module | File budgets, symlinks, format tests |
| Menu-bar and desktop character renderer | SchneeRunnerApp | New SchneeBar-owned renderers/coordinator | One status item; window lifecycle |
| CPU, battery, memory triggers | Both | SharedMetricsService | One sampler / interval ownership |
| Local build/character distributed events | SchneeRunnerApp | Display-only untrusted event adapter | No credential or write path |
| Timers, Pomodoro, reminders, history | SchneeRunnerCore + App | ProductivityCore + notification adapter | Deadline/restart/idempotency tests |
| Launch at login | Both app lifecycles | SchneeBar-only ownership | Old login item handled explicitly |
| Historical Runner state and character library | SchneeRunner Application Support | Versioned copy-only importer | Atomic, reloaded, rollback |
| Localization | SchneeRunner ja/en; SchneeBar features | Design System-driven UI language audit | ja/en parity |
| Release assets/signing | Both release policies | SchneeBar release pipeline | Provenance, sign, notarize |

## Product surface

- **Home**: widgets and priorities, minimized by default.
- **Dev**: GitHub workflows, reviews, checks, connection selection/health, existing action confirmations.
- **Focus**: timers, Pomodoro, reminders, snooze and history.
- **Character**: optional menu-bar/desktop renderer, packs and CPU/event reactions.
- **Connections & Security**: per-account origin, identity, permissions, token health and local vs remote disconnect explanations.
- User modes are presentation presets (Minimal / Dashboard / Companion), **not** distinct security capabilities.

## Architecture boundaries

1. `SchneeBar.app` composes new `CompanionCore` and `ProductivityCore` as inward-facing pure logic; adapters own AppKit, IOKit, UserNotifications and FileManager.
2. Only GitHub integration retrieves/uses tokens. Convert provider events to a small bounded, redacted `DeveloperActivitySignal` (source ID, repo ID, event kind, timestamp, severity, expiry), and pass it one-way to companion.
3. External Widget documents and local Distributed Notifications are **not authenticated commands**. They may change visual state after validation; they cannot rerun workflows or change accounts.
4. Single shared CPU sample timestamp/host ticks, calibrated refresh policy and optional EMA smoothing; domain consumers do not independently query Mach counters. Host CPU percentages are not per-process Activity Monitor CPU percentages.
5. Only the active app owns notification category identifiers and `SMAppService` registration. During parallel installation, prevent duplicate reminders by opt-in cutover and explicit cleanup.
6. No direct SwiftUI/Keychain or SwiftUI/URLSession dependency. App delegate and menu item lifecycle remain in SchneeBar.
7. Character asset files are data, never executable code. Retain existing decompression limits, canonicalization, symlink defenses and staged import/reload.

## Migration contract

- Detect old Runner app data only with user consent; never silently take over credentials (Runner currently has none) or delete source.
- Version the importer (`migrationVersion`, source app id, source schema version and target scope). Stable item IDs for idempotency; avoid cross-app status collisions.
- Snapshot and validate old character library, preferences, timer/reminder records, history; parse using legacy decoders and defensive file size constraints.
- Stage destination copy with safe filesystem permissions and non-symlinked paths, validate full roundtrip, atomically commit and record completion.
- Separate migration of notification schedules from state copy. Register only new owned notifications after source application reminders are intentionally disabled; show clear coexistence guidance.
- On failure: original app untouched, no partial new schedule, visible retry and diagnostics. On rollback: keep original intact; remove only new migration-owned resources.

## Proposed performance and SLO *targets* (not measured facts)

Measure on a fixed Mac device and build configuration; establish pre-integration baseline for both apps. Initial experimental targets: idle CPU average <= 1% with companion disabled and no active CI poll; steady resident memory <= 200 MiB; menu bar visible <= 2 s; no repeated reminder delivery. These are provisional gates, revised after profiling. Track macOS Energy Log, wakeups, per-process CPU, memory and animation frame rate.

## Delivery order

0. Review/freeze inventory and ADR in this proposal; no migration or deletion yet.
1. Harden GitHub credentials/transport in a separately reviewable change.
2. Extract and port deterministic CompanionCore tests and one non-intrusive renderer (feature flag off by default).
3. Establish shared metrics (one CPU sampler), preserving semantics and current widget correctness.
4. Port productivity state and notifications with old-app coexistence policy.
5. Integrate optional UI/visual harness and bounded GitHub activity reactions.
6. Copy-only data migration, threat and asset provenance review, real-Mac regression, then release decision.

## Open questions requiring evidence

- Sign/notarize identity and artifact distribution terms for the combined app; current license is undecided.
- Runtime notification entitlement/authorization effects for unsigned previews vs signed builds.
- macOS 14 user migration/upgrade expectations after targeting 15+.
- Per-application bundle-id and login item behavior during coexistence.
- Character resource provenance and acceptable default distributable artwork.
- Actual performance/CPU usage before assigning binding SLOs.

Links: [Architecture](ARCHITECTURE.md), [GitHub integration](GITHUB_INTEGRATION.md), [Release](RELEASE.md), [Security plan](SECURITY_HARDENING_PLAN.md), [ADR-0004](decisions/0004-schneerunner-integration-boundaries.md).

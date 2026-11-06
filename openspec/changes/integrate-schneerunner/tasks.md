# Tasks: Integrate SchneeRunner

## 1. Baseline and scope

- [x] 1.1 Inventory existing modules, source formats, deployment targets and accepted ADRs; evidence: docs/SCHNEERUNNER_INTEGRATION.md and ADR-0004 proposal.
- [x] 1.2 Create proposed OpenSpec delta capabilities; evidence: companion, productivity, integration-boundaries, integration-settings spec files.
- [ ] 1.3 Review source license and character artwork provenance; verify explicit recorded decision before copying or redistributing assets.
- [ ] 1.4 Capture exact source commit SHAs and existing SchneeBar/Runner behavior on a real Mac; verify reproducible version-and-device baseline report.
- [ ] 1.5 Review and accept/modify ADR-0004; verify written decision and agreed macOS 15+ compatibility boundary.
- [ ] 1.6 Run OpenSpec strict validation for this change and record CLI output; verify zero findings before implementation review.

## 2. Port pure CompanionCore

- [ ] 2.1 Create inward-facing domain targets and compile an initial RunnerCore animation policy slice under Tuist; verify Swift test target builds.
- [ ] 2.2 Port state priority/TTL/cooldown and animation schedule tests; verify deterministic agreement with original RunnerCore fixtures.
- [ ] 2.3 Port character pack format/clip parsers, canonicalization and defensive resource limits; verify malformed symlink/path/decode test corpus is rejected.
- [ ] 2.4 Add feature-flagged menu-bar character renderer without a second status item; verify single NSStatusItem and existing widget visual snapshots.
- [ ] 2.5 Add optional desktop renderer with hide, click-through and reduced-motion preferences; verify real-Mac window and accessibility behavior.

## 3. Consolidate platform services

- [ ] 3.1 Capture current host CPU metric units and Activity Monitor mismatch issue #365; verify baseline written with raw/smoothed and per-process distinctions.
- [ ] 3.2 Implement one shared host CPU sample owner with multiple subscriptions; verify a test spy sees exactly one acquisition per interval with widget+character active.
- [ ] 3.3 Preserve counter-regression, sleep/wake and stale-generation rules; verify deterministic policy tests and host CPU widget regression.
- [ ] 3.4 Implement bounded local-build/character event parsing for display-only reactions; verify spoofed/oversized payloads produce zero GitHub mutation calls.
- [ ] 3.5 Add lifecycle and resource profiling; verify collected CPU, memory, wakeups and animation frame metrics against measured baseline.

## 4. Focus productivity and notifications

- [ ] 4.1 Port countdown/Pomodoro deadline-authoritative state and recovery tests; verify sleep/restart cannot extend timers.
- [ ] 4.2 Port recurrence, weekday/DST, snooze and history models; verify deterministic calendar fixtures.
- [ ] 4.3 Provide one app-owned notification coordinator and namespaced request IDs; verify startup reconciliation is idempotent and supports permission denial.
- [ ] 4.4 Test old/new app simultaneous installation and reminder-owner cutover; verify zero duplicate notifications and zero silently overwritten Runner schedules.
- [ ] 4.5 Provide Focus UI under SchneeBar Design System; verify keyboard, VoiceOver, Japanese/English and visual fixtures.

## 5. User experience and connected events

- [ ] 5.1 Add enable/disable controls and Minimal/Dashboard/Companion presentation presets; verify toggling never changes GitHub authorization.
- [ ] 5.2 Add companion asset selection/import and safe missing-asset fallback; verify malformed file and renderer failure tests.
- [ ] 5.3 Gate GitHub character reaction on completion of harden-github-connections security review; verify issue #368/#369 acceptance evidence.
- [ ] 5.4 Add credential-free GitHub activity projection, allowlist and deduplication; verify stale/canceled connections cannot emit new reactions.
- [ ] 5.5 Exercise untrusted event-to-write attack tests across local notifications and external widgets; verify zero network mutation requests.

## 6. Data migration, regression and release

- [ ] 6.1 Implement opt-in copy-only Runner data inventory and staged migration; verify original storage remains unchanged on success and failure.
- [ ] 6.2 Add versioned idempotency markers, atomic reload verification and rollback handling; verify retries/crash windows create no duplicate data.
- [ ] 6.3 Test source/target schema drift, symlinks, corrupt files and partially imported histories; verify rejection/repair and observable error state.
- [ ] 6.4 Run full SchneeBar build/tests, visual harness and macOS signed/unsigned notification smoke; verify regression report and actioned failures.
- [ ] 6.5 Benchmark real-Mac idle CPU/memory/wakeups across feature flag combinations; verify documented measured numbers and revised budgets.
- [ ] 6.6 Review distribution terms, universal binary, artwork provenance, signing/notarization and release gates; verify checklists before publishing.
- [ ] 6.7 Review Runner-to-Bar feature parity, user migration and rollback; verify explicit approval before any announcement of Runner end-of-life.

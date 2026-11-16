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

## 7. Review closure acceptance tasks (not implemented)

- [ ] 7.1 Inventory Runner Application Support and all UserDefaults keys/bundle domains, including character selection and desktop visibility; verify source-to-target map and accessible/export-only fallback on signed Mac.
- [ ] 7.2 Implement versioned copy-only migration marker and old-to-new asset UUID remapping; verify source storage is unmodified and partial preference omissions are visible.
- [ ] 7.3 Enforce first-release imported notification data-only state across all Runner versions; verify no imported timer/reminder/Pomodoro notification can activate via UI/restart/event while new Bar-native reminders remain functional. Implement future stop/ACK only in separately approved change.
- [ ] 7.4 Test migration while notification permission is denied or source app cannot communicate; verify destination reminders remain inactive and no false completion is shown.
- [ ] 7.5 Preserve floating system-local recurrence using Calendar matchingPolicy nextTime and repeatedTimePolicy first; verify Tokyo/New York DST, travel, manual clock changes and stable occurrence dedup.
- [ ] 7.6 Implement raw local-event 4096-byte ceiling, 12 set + 4 reserved terminal events/second, 128 ingress-attempt ceiling, 64 active-channel cap and 1800-second fallback lease; verify threshold, clearance on reserve overflow, storm quarantine and zero GitHub mutation fixtures.
- [ ] 7.7 Differentiate recoverable render failures from fatal app crashes in UI and recovery flow; verify safe-mode relaunch behavior and no claim of in-process crash isolation.
- [ ] 7.8 Review newly proposed numeric event budgets on a real Mac with synthetic load; verify the final performance numbers before enabling Companion event bridging.

## 8. Re-review closure: handoff scope and local-event termination

- [ ] 8.1 Make imported Runner reminder/timer/Pomodoro notifications inactive by default and unenableable in initial integrated release; verify old Runner pending schedules remain untouched, two-app restarts never register a duplicate and new Bar-created notifications remain usable.
- [ ] 8.2 Define user-facing data-only limitation and future protocol requirements (signed/authenticated peer identity, source revision, nonce/replay, durable stop evidence); verify raw distributed notifications and user-confirm-only flags never set `runnerDisabledVerified`.
- [ ] 8.3 Implement 12 update + 4 reserved clear/cancel budget and a fail-closed volatile-state clear on terminal overflow; verify valid clear after update saturation, 5th terminal clear and 129th raw ingress attempt cannot leave a stale local trigger.
- [ ] 8.4 Measure the initial bounded event ingress and fail-safe rendering on a Mac; verify privacy-safe diagnostics and ensure GitHub/Focus aren't canceled by a local event storm.

## 9. Implementation-ready slices and evidence (2026-11-15)

All tasks are pending; the [implementation and parity contract](implementation-parity-contract.md) defines the proposed order. These refine sections 1–8, not duplicate implementation mandates. Complete related original task only when its complete scope is evidenced.

- [ ] 9.1 (PR-A preflight) Record maintainer reuse/asset rights and ADR-0004 disposition; exact SHA, target dependency graph and full source-test parity ledger; strict OpenSpec output. Stop reuse if approval unavailable.
- [ ] 9.2 (PR-A / #370) Implement pure C1 policy target and focused tests; input metric→system advisory→event→manual→clear, equal priority renewals, empty fallback; expected priorities 100/300/400/500/1000, newest tie and run fallback; verify no platform/GitHub imports. No assets/UI in this PR.
- [ ] 9.3 (PR-B / #365) Shared sample adapter; fake counter+clock for concurrent requests, first/invalid sample, disable last subscriber while in-flight, sleep/wake; expected one owner, stale generation dropped, no fabricated 0%, existing widget fixture preserved.
- [ ] 9.4 (PR-C) Asset corpus and feature-flagged menu renderer, then desktop PR; expected reject malicious/symlink/oversize input without owned partial copy, exact clip fallback and one NSStatusItem; real-Mac display recovery, click-through escape and motion-off-on-launch checks.
- [ ] 9.5 (PR-D) Verify actual v1 CLI wire fixtures and coexistence warning; expected build started→dash, succeeded→sprint for 2s, failed→idle for 5s, cancel clears, lease expires; existing ingress caps and zero GitHub writes; no CLI replacement.
- [ ] 9.6 (PR-E) Native Focus domain, notification adapter and UI separately; expected fake clock deadline reconciliation once, recurrence DST fixtures, 500-entry history compatibility (source README), disabled surface does not cancel native schedules, permission-denied fallback is labeled and imported definitions inactive.
- [ ] 9.7 (PR-F) Complete preference/file inventory and journal fault injection; expected source bytes unchanged, repeat import deduped, native concurrent edit not overwritten, imported schedules inactive; rollback preserves native records and source login item.
- [ ] 9.8 (PR-G) Record explicit security acceptance links for #368/#369 and current hardening change; expected no raw token/API capability or stale generation in character projection, default opt-out, old GitHub navigation retained.
- [ ] 9.9 (PR-H) Execute fixed-device baseline matrix, visual scenarios (ja/en, disabled state, focus, character, existing activity/detail/history), accessibility/keyboard, signed/unsigned launch/schedule test; attach actual evidence and approve release/rollback, retain Runner until explicit separate end-of-life approval.

## 10. C1 decomposition

- [ ] 10.1 Review C1a contract and proposed capacity limits; evidence: approved scope and ADR disposition, recorded source reuse decision before any source copying.
- [ ] 10.2 Implement isolated C1a state arbitration and A01–A08 fixtures; evidence: exact target/test paths, isolated Swift results and macOS Tuist build/test.
- [ ] 10.3 Implement C1b clip selection and timing; evidence: unchanged clip and per-frame duration fixtures with documented equivalence.
- [ ] 10.4 Implement C1c EMA/hysteresis; evidence: source-pinned threshold and boundary fixtures, manual speed tests and invalid sample behavior.

## 11. C1 re-review and playback/CPU policy slices

- [ ] 11.1 Add C1a timestamped clear/quarantine and maximum local lease tests; verify stale timestamp, elapsed underlying state and accepted/rejected insertion behavior.
- [ ] 11.2 Implement C1b bounded timing, default catalog, exact rates and single-use cursor tick token; verify B01–B05 fixtures, no production renderer connectivity.
- [ ] 11.3 Implement C1c pure EMA/hysteresis and invalid sample reset; verify C01–C03; keep C04 runtime wiring under PR-B and do not claim exact time-response parity.
- [ ] 11.4 Verify every C1 implementation target actually appears in macOS Tuist test execution (CI success alone does not prove the new suite ran); record test counts/logs and full fixture ledger. Review proposed bounds and ADR before merging.

## 12. Shared CPU ownership rollout

- [ ] 12.1 PR-B1: extract demand-driven shared host sampler, preserve widget formatting, compile and verify old/new fake clock, counter, cache, error, and cancellation fixtures.
- [ ] 12.2 PR-B2: app-owned shared instance with configuration-revision and sleep/wake fencing; verify final unsubscribe, both-consumer and single-consumer modes, distinct sample IDs for Companion EMA, and no new autonomous polling loop.
- [ ] 12.3 Validate aligned whole-machine comparison and same-device performance; capture real measurements before default activation.

## 13. B2 lifecycle and Companion input

- [ ] 13.1 Verify app-owned sampler, serialized demand/engine configuration changes, CPU-only and zero-consumer modes, sleep/wake and scoped WidgetEngine runtime invalidation.
- [ ] 13.2 Verify CompanionCPUInput newest-request/session fence, cached sample deduplication, unavailable/reset and manual/automatic transitions.
- [ ] 13.3 Connect actual opt-in Companion renderer/settings to managed demand and existing scheduler, preserving a single owner and no polling when disabled. Not included in B2a.
- [ ] 13.4 Execute macOS tests and real-device lifecycle/power checks; record CI/test counts, remaining compatibility exceptions and approval.

## 14. Asset and renderer slices

- [ ] 14.1 C2a: verify bounded Data-only decoding, format check, aggregate budget and generated fixtures on macOS; review decoder memory limits.
- [ ] 14.2 C2b/C2c: file/pack import, owned staging, traversal/symlink/TOCTOU, all-format fixtures, export and catalogue resource limits as specified in companion-assets-renderer-contract.md.
- [ ] 14.3 C3a: verify isolated frame driver and static fixture, deterministic async cancellation/Reduce Motion integration before app connection.
- [ ] 14.4 C3b: approved opt-in UI, application-owned status item, CPU demand/renderer lifecycle, accessible fallback and disable/recovery evidence.

## 15. Bounded single-file intake and coordinator

- [ ] 15.1 Verify descriptor-based bounded local file intake: valid, final symlink, directory, FIFO, empty, oversize and non-file URL; add deterministic mutation/read fault fixtures before enabling user import.
- [ ] 15.2 Verify retained catalogue budget, fallback/alias behavior; add a cumulative boundary fixture without excessive CI allocations and pre-decode aggregate accounting for pack imports.
- [ ] 15.3 Verify coordinator opt-in, manual state versus speed, fallback continuity, stale request rejection, sleep, Reduce Motion and asset removal. No host demand or UI wiring until separately reviewed.
- [ ] 15.4 Integrate app-owned single status item, off-main single-flight import and atomic publication, shared sampler scheduling, settings/UI and localized accessible fallback; keep production gate until approvals and real-device verification.

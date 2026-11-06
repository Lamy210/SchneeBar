# Implementation tasks

## 0. Decision and baseline

- [x] Inventory SchneeBar and SchneeRunner main architectures, version baselines and core capabilities.
- [x] Prepare proposed ADR-0004 and integration matrix.
- [x] Document existing accepted ADR-0002 and avoid a silent auth-flow migration.
- [ ] Review rights/licensing/provenance for copying domain code and assets.
- [ ] Record exact tested source SHAs and security/performance baseline on macOS.
- [ ] Approve ADR-0004 and OpenSpec delta requirements.

## 1. Security prerequisite (separate change)

- [ ] Complete `harden-github-connections` acceptance gates before enabling GitHub-triggered companion events.

## 2. Pure CompanionCore extraction

- [ ] Extract animation schedules, trigger engine, asset loaders and character pack policies into an inward-facing target.
- [ ] Port or link existing deterministic RunnerCore tests including malicious pack cases.
- [ ] Add feature-flagged menu bar renderer without creating a second `NSStatusItem`.
- [ ] Add optional desktop renderer with independent lifecycle and reduced-motion support.

## 3. Shared metrics and local events

- [ ] Implement one shared Mach host CPU sampler and consume it from widget and character adapters.
- [ ] Preserve raw vs smoothed host CPU semantics and counter-regression handling.
- [ ] Add bounded, sanitized local display-only build event adapter and cancellation/TTL tests.
- [ ] Profile idle CPU/memory/wakeups with and without animation.

## 4. Productivity

- [ ] Extract deadline-authoritative timers, Pomodoro and reminders with state/history tests.
- [ ] Implement notification owner/identifier scoping, startup reconciliation and restart/sleep tests.
- [ ] Implement opt-in user notification consent; verify signed/unsigned behavior.

## 5. UX and GitHub activity reactions

- [ ] Implement Focus/Character surfaces and settings using SchneeBar Design System.
- [ ] Add deterministic visual fixtures and VoiceOver/ja/en/reduced-motion checks.
- [ ] After security gate, add credential-free GitHub activity projection with priority/TTL/cooldown tests.
- [ ] Assert 0 GitHub mutation calls from all untrusted character/local events.

## 6. Migration and release

- [ ] Implement copy-only, versioned Runner → SchneeBar migration with staged write/reload and rollback.
- [ ] Test duplicate-run idempotency, corrupted files, symlink and image decompression budgets.
- [ ] Test concurrent installation, launch at login and notification cutover.
- [ ] Measure acceptance targets on real Mac; document actual results and revise provisional targets.
- [ ] Verify distribution terms, artwork provenance, stable signing/notarization and universal build.
- [ ] Review parity before recommending Runner archival; do not archive automatically.

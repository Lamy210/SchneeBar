# Proposal: Integrate SchneeRunner capabilities into SchneeBar

## Why

SchneeBar offers a coherent native menu-bar UI and GitHub integration; SchneeRunner provides richer character animation, local events and productivity functions. Running both separately duplicates lifecycle, CPU sampling and notification ownership and fragments settings.

## What Changes

- Add optional Character and Focus surfaces under SchneeBar's current SwiftUI/AppKit composition root.
- Reuse compatible SchneeRunnerCore domain behavior and asset validation, not its AppDelegate or second status item.
- Share host metrics and platform scheduling with existing widgets.
- Project sanitized, read-only GitHub activity into character reactions without giving character code GitHub credentials or mutation privileges.
- Provide settings, accessibility and local-only functionality independent of GitHub sign-in.
- Provide copy-only opt-in migration with explicit reminder ownership cutover and non-destructive rollback.
- Preserve SchneeBar developer features and current macOS 15+ minimum.

## Capabilities

### New Capabilities

- `companion`: Opt-in character display, asset safety, animation reactions and accessibility.
- `productivity`: Timers, Pomodoro, recurring reminders, notification ownership and durable state.
- `integration-boundaries`: Shared metrics and strictly separated GitHub-to-Companion data signals.
- `integration-settings`: Unified feature configuration, connection-aware presentation and accessibility.

### Modified Capabilities

- None. No canonical `openspec/specs/` baseline has been established for these features yet; this change introduces capabilities without claiming existing ones are already implemented.

## Impact

- App modules: SchneeBarApp, SchneeBarCore, SchneeBarDesignSystem, SchneeBarSystemProvider, SchneeBarGitHubActivityProvider; new Companion/Productivity/metrics/migration adapters.
- Source reference: `Lamy210/SchneeRunner` and its SwiftPM Core tests.
- Platform: Swift 6, Tuist, AppKit, SwiftUI, macOS 15+; no new mandatory server.
- Dependencies: GitHub-origin character events are gated on the independent `harden-github-connections` change (issues #368 and #369). Local-only Companion extraction (issue #370) can proceed in parallel.
- Release: no bundled artwork until rights/provenance is confirmed; no Runner archival until migration and feature parity pass.

## Non-Goals

No one-shot merge, no implicit migration, no macOS 14 guarantee, no changes to accepted ADR-0002, no new GitHub write commands from character events, and no instant signed stable release.

## Validation / rollback

Review ADR-0004, verify contracts and task checklist with OpenSpec, preserve old data, and make each new module disableable independently. Disable or roll back a failing module without modifying existing SchneeBar GitHub credentials.

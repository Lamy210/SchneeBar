# Proposal: Integrate SchneeRunner into SchneeBar

## Why

The native SchneeBar UI and GitHub activity foundation and SchneeRunner's character/productivity features currently require separate running applications. They duplicate menu-bar lifecycle, CPU measurement, scheduling and user settings. Users need an optional one-app experience without weakening GitHub security or losing local data.

## What changes

- Add independently toggleable Companion and Productivity modules inside the SchneeBar app, preserving SchneeBar Design System.
- Adapt SchneeRunner's reusable core models, asset guards and deadline-based state reconciliation rather than copying its AppKit application lifecycle.
- Introduce single-owner system metrics, notifications and login-item coordination.
- Add bounded credential-free Developer Activity signals for character reactions, never GitHub commands.
- Add a versioned, idempotent, copy-only migration from local SchneeRunner state.
- Maintain existing Developer Activity and all current SchneeBar widget behavior.

## In scope

Architecture and UI contract, adapter boundaries, migration safeguards, initial integration test gates and phased implementation. macOS 15+ for initial integration.

## Out of scope

Immediate code migration in this proposal; archiving SchneeRunner; changing GitHub authentication ADR-0002; macOS 14 support; requiring cloud infrastructure; importing unverified third-party character assets; merging or enabling write permissions.

## Dependencies

`harden-github-connections` is a prerequisite to exposing new GitHub-to-Companion activity integration; local-only CompanionCore work can proceed independently.

## Impacted components

SchneeBarApp, SchneeBarCore, SchneeBarDesignSystem, SchneeBarSystemProvider, SchneeBarGitHubActivityProvider, new Companion/Productivity modules, notification/migration adapters, visual harness and tests. Source reference: `Lamy210/SchneeRunner` main.

## Acceptance for this change

Specification and design review first; tasks remain unchecked until implementation and real-Mac evidence exist. See [ADR-0004](../../../docs/decisions/0004-schneerunner-integration-boundaries.md).

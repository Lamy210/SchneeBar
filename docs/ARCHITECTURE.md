# Architecture

## Goals

SchneeBar is a long-lived native macOS utility. The architecture therefore optimizes for low idle overhead, clear platform boundaries, deterministic testing, provider portability, and resilience to macOS/GitHub API evolution.

## Style

**Modular Monolith + Ports & Adapters.**

```text
SchneeBar App
  |
  +-- Presentation
  |     +-- Menu Bar (AppKit / NSStatusItem)
  |     +-- SwiftUI Popovers
  |     +-- Settings
  |
  +-- Application
  |     +-- WidgetEngine
  |     +-- ActivityAggregator
  |     +-- VisibilityPolicy
  |     +-- NotificationPolicy
  |
  +-- Domain
  |     +-- Activity
  |     +-- Pipeline
  |     +-- PullRequest
  |     +-- Deployment
  |     +-- ConnectionCapability
  |
  +-- Ports
  |     +-- ActivityProvider
  |     +-- CredentialStore
  |     +-- ActivityStore
  |
  +-- Adapters
        +-- GitHub
        +-- System
        +-- Keychain
        +-- SQLite (planned)
```

## Dependency rule

Dependencies point inward. Domain models are provider-neutral and UI-neutral.

Forbidden examples:

- `SwiftUI.View` inside Domain
- GitHub API response types inside Presentation
- direct URLSession calls from views
- direct Keychain calls from views

## UI boundary

AppKit owns macOS integration where required (`NSStatusItem`, panel/popover lifecycle). SwiftUI owns composable content and settings.

The first implementation deliberately keeps the visible component in `SchneeBarDesignSystem` so the same view is used by the app, the local Visual Harness, and CI rendering.

## Concurrency

Swift 6 language mode is the baseline. UI/platform objects are main-actor owned. Provider/cache/network work will be actor-isolated or explicitly concurrent. New GCD-based architecture is avoided unless an Apple framework requires it.

## Provider design

GitHub integration must be connection-driven, not hard-coded to `api.github.com`:

```text
GitHubProvider
    |
GitHubConnection
    |
CapabilitySet
    +-- GitHub.com
    +-- GHE.com
    +-- GHES
```

Capabilities, authentication, API versions, endpoints, and rate-limit budgets belong to the connection layer.

## Persistence

SQLite/GRDB is planned for cached activity and configuration once persistent provider data exists. Secrets are stored only in Keychain.

## Performance principle

A menu-bar utility should be mostly asleep. Prefer events/adaptive refresh over fixed high-frequency polling. Idle CPU and wakeups are product metrics, not only implementation details.

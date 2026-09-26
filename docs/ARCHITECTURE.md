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
  |     +-- Activity Feature (SwiftUI)
  |     +-- Settings
  |
  +-- Design System
  |     +-- Surfaces / materials
  |     +-- typography / spacing / primitives
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
  |     +-- ActivitySource
  |     +-- CredentialStore
  |     +-- ActivityStore
  |
  +-- Adapters
        +-- GitHub
        +-- System
        +-- Keychain
        +-- SQLite (planned)
```

## Current module boundaries

- `SchneeBarCore`: provider-neutral domain/application primitives only. It owns the normalized `ActivitySource` port, bounded/privacy-minimized provider identity rules, deterministic multi-source aggregation, and the canonical Widget provider-ID registration boundary. `WidgetID` decoding remains permissive for persisted preference compatibility; runtime provider registration/replacement is the capability boundary. The descriptor captured at registration is authoritative for that provider lifetime; returned snapshots must carry the exact same descriptor before entering runtime/UI state, provider refresh policies must remain finite at the registration capability boundary, and refresh cancellation is lifecycle control rather than provider failure. Provider-specific polling and failures stay outside Core.
- `SchneeBarDesignSystem`: reusable visual primitives and surfaces; it must not know Developer Activity domain types.
- `SchneeBarActivityFeature`: Developer Activity presentation. Depends on Core + DesignSystem.
- `SchneeBarExternalWidgets`: strict external-widget document adapter plus bounded read-only Application Support loader. Depends on Core, normalizes into existing widget models, and adds no execution, network, credential, or direct WidgetEngine mutation capability.
- `SchneeBarPreviewSupport`: deterministic fictional fixtures used only by visual/test tooling.
- `SchneeBar`: composition root and macOS integration. It performs one startup external-widget load and atomically replaces the dedicated provider group; filesystem watching remains outside the App runtime. Production UI does not depend on PreviewSupport.
- `SchneeBarVisualHarness` / `SchneeBarVisualSnapshotCLI`: development and CI tooling.

## Dependency rule

Dependencies point inward. Domain models are provider-neutral and UI-neutral.

Forbidden examples:

- `SwiftUI.View` inside Domain
- feature/domain-specific views inside `SchneeBarDesignSystem`
- preview/test fixtures inside production Core
- GitHub API response types inside Presentation
- direct URLSession calls from views
- direct Keychain calls from views

## UI boundary

AppKit owns macOS integration where required (`NSStatusItem`, panel/popover lifecycle). SwiftUI owns composable feature content and settings.

Feature views are shared by the app, local Visual Harness, and deterministic CI renderer. Visual fixtures are injected from PreviewSupport rather than compiled into production Core.

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

# SchneeBar

SchneeBar is a native macOS menu-bar platform for surfacing the information and actions that matter **right now**.

The project is in its bootstrap phase. The first vertical slice focuses on a native menu-bar shell, clear Core / DesignSystem / Feature boundaries, deterministic visual rendering, and public-repository-safe CI.

## Product direction

- Customizable macOS menu-bar widgets
- Context-aware visibility and prioritization
- Developer Activity: CI, pull requests, reviews, deployments
- GitHub.com, GitHub Enterprise Cloud / GHE.com, and self-hosted GitHub Enterprise Server
- System widgets such as CPU, memory, network, battery, and clock
- Local-first operation with optional integrations

SchneeBar is a separate product from SchneeGlass. Any future integration is optional.

## Current stack

- macOS 15+
- Xcode 26.6 / Swift 6.3 stable track
- SwiftUI + AppKit (`NSStatusItem`)
- Swift Concurrency and Observation-oriented architecture
- Tuist 4.203.1, pinned with mise
- Swift Testing for unit tests
- GitHub Actions on macOS 26
- Adaptive local Visual Harness + deterministic PR-base visual regression
- CodeQL and Dependabot

Xcode 27 / Swift 6.4 preview support is tracked in a non-blocking canary lane, not as the production baseline.

## Architecture

SchneeBar starts as a modular monolith using Ports & Adapters:

```text
App / macOS integration
        |
Activity Feature
   /           \
Core       DesignSystem
        |
Future provider ports/adapters
```

Production domain types stay UI-neutral, the Design System stays feature-neutral, and preview fixtures live in a dedicated development-only target. Provider DTOs must not leak into SwiftUI. See [Architecture](docs/ARCHITECTURE.md).

## Local development

Requirements:

- macOS Tahoe 26.2+ for the pinned Xcode 26.6 toolchain
- Xcode 26.6
- mise

```bash
mise install
mise exec -- tuist generate
mise exec -- tuist build
mise exec -- tuist test
mise exec -- tuist run SchneeBar
```

Open the visual development harness (adaptive macOS surface):

```bash
mise exec -- tuist run SchneeBarVisualHarness
```

Render deterministic visual scenarios used by CI:

```bash
mise exec -- tuist run SchneeBarVisualSnapshotCLI -- --output .visual/current
```

## CI and visual review

Every pull request builds and tests the native app. A separate Visual Regression workflow renders deterministic scenarios from the pull request candidate and its exact base commit (`pull_request.base.sha`), then produces an HTML report with Before / After / Overlay views.

The blocking-capable snapshot layer deliberately uses a deterministic surface instead of treating off-screen Liquid Glass/vibrancy rendering as a stable pixel oracle. Full adaptive-material screenshots are planned as a separate XCUITest smoke layer.

See [CI & Visual Regression](docs/CI_VISUAL_REGRESSION.md).

## Public repository policy

This repository is public. CI is therefore designed with untrusted fork pull requests in mind:

- PR jobs receive no application/release secrets.
- Workflow permissions default to read-only.
- We do not execute PR code under `pull_request_target`.
- Checkout credentials are not persisted into PR worktrees.
- Third-party actions are pinned to immutable commit SHAs.
- Signing, notarization, and release credentials belong only in protected release workflows/environments.
- GitHub OAuth/App credentials must never be committed or embedded as private secrets in the public client.

See [Public Repository Security](docs/PUBLIC_REPOSITORY_SECURITY.md) and [Security Policy](SECURITY.md).

## Project documents

- [Architecture](docs/ARCHITECTURE.md)
- [Development Plan](docs/DEVELOPMENT_PLAN.md)
- [GitHub Integration](docs/GITHUB_INTEGRATION.md)
- [CI & Visual Regression](docs/CI_VISUAL_REGRESSION.md)
- [Public Repository Security](docs/PUBLIC_REPOSITORY_SECURITY.md)
- [ADR-0001: Native modular architecture](docs/decisions/0001-native-modular-architecture.md)

## License

A project license has **not yet been selected**. Source visibility on GitHub is not itself an open-source license. Until the maintainer chooses a license, external code contributions are intentionally deferred; issues and design feedback are welcome.

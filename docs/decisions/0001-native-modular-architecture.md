# ADR-0001: Native modular architecture and stable/preview toolchain lanes

- Status: Accepted
- Date: 2026-09-12

## Context

SchneeBar needs deep macOS integration, low idle overhead, a highly customized menu-bar experience, deterministic UI review, and future provider integrations including GitHub Enterprise.

## Decision

Use a native Swift application with:

- stable production baseline: Xcode 26.6 / Swift 6.3
- SwiftUI for composable UI and AppKit for menu-bar/platform integration
- Tuist-generated Xcode project, pinned with mise
- modular monolith / Ports & Adapters boundaries
- Swift Testing for domain/application tests
- deterministic Visual Harness shared between local development and CI
- future Xcode/Swift previews only in non-blocking canary CI

## Consequences

Positive:

- native APIs and performance
- provider/platform code can evolve independently
- UI changes are reviewable in PR artifacts
- Enterprise GitHub support does not require replacing UI architecture

Costs:

- AppKit/SwiftUI interoperability needs explicit ownership rules
- Tuist is another development tool to maintain
- macOS visual rendering requires controlled CI conditions
- preview toolchains cannot become release dependencies until stable

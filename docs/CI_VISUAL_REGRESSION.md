# CI & Visual Regression

## Why two levels

Whole-desktop/menu-bar pixel tests are inherently noisy because of time, third-party status items, OS patch rendering, scale, wallpaper, animation, and compositor-driven materials. Therefore SchneeBar separates:

1. **Deterministic component rendering** — blocking-capable foundation
2. **Real app/UI smoke screenshots** — E2E evidence for platform/material behavior

## Current implementation

`SchneeBarVisualSnapshotCLI` renders fixed Developer Activity and Widget Feature fixture scenarios using the same feature views as the real app, but with a deterministic surface instead of Liquid Glass/vibrancy.

This is intentional: off-screen `NSHostingView` capture is not a reliable pixel oracle for compositor-driven glass/material effects. The deterministic layer validates layout, typography, semantic state colors, scrolling/truncation, feature composition, and widget priority/severity presentation. Real adaptive glass remains visible in the local Visual Harness and will later be covered by XCUITest smoke screenshots.

Developer Activity scenarios currently cover:

- normal
- running
- main failure
- waiting-only
- mixed Enterprise/GitHub contexts
- overflow / long repository names
- light/dark appearances

Widget scenarios currently cover:

- nominal CPU + Clock
- attention/running state
- critical state
- many-widget composition
- light/dark appearances

Snapshots use an explicit light/dark backdrop and deterministic card surface so text/status colors remain reviewable in arbitrary artifact viewers.

## Baseline selection

A PR must be compared against its exact GitHub pull-request base commit, not whatever `main` happens to contain when the workflow starts.

The workflow therefore checks out:

- candidate: GitHub's PR checkout candidate
- baseline: `${{ github.event.pull_request.base.sha }}`

This avoids unrelated changes that land on `main` after the PR event from contaminating the visual comparison.

## Report

The PR workflow renders both versions on the same macOS/Xcode runner, then generates an HTML report with:

- Before image
- After image
- opacity/overlay slider
- NEW / REMOVED / CHANGED / UNCHANGED state based on SHA-256 of rendered PNGs

No binary baseline needs to be manually committed. The canonical baseline is the PR base code rendered in the same job.

## Bootstrap behavior

The first PR cannot render a baseline if its base commit predates the renderer. Its candidate images are reported as `NEW`. After the bootstrap PR is merged, later PRs get real before/after comparison automatically.

## Why the report does not yet fail on a changed pixel

The first goal is reviewability and renderer stability. macOS rasterization tolerance needs empirical data before a pixel/perceptual threshold becomes a required check. Once stable, a later ADR can introduce a blocking threshold or a fixed self-hosted Mac visual runner.

## Toolchain lanes

The required lane is pinned to Xcode 26.6 / Swift 6.3 on `macos-26`. A separate scheduled `xcode-27` public-preview canary is intentionally non-blocking. Preview runner failures are compatibility signals, never release or merge gates.

## Future layers

- XCUITest smoke flow: click status item, open popover/settings
- full-app screenshots that exercise real Liquid Glass/materials
- accessibility variants (increased contrast/reduced transparency)
- fixed self-hosted Mac only if GitHub-hosted raster differences become materially flaky
- optional perceptual image diff after tolerance is calibrated

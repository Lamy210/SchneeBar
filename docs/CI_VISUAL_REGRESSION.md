# CI & Visual Regression

## Why two levels

Whole-desktop/menu-bar pixel tests are inherently noisy because of time, third-party status items, OS patch rendering, scale, wallpaper, and animation. Therefore SchneeBar separates:

1. **Deterministic component rendering** — blocking-capable foundation
2. **Real app/UI smoke screenshots** — later E2E evidence, not the sole pixel gate

## Current implementation

`SchneeBarVisualSnapshotCLI` renders fixed Developer Activity fixture scenarios using the same `SchneeBarDesignSystem` view as the real app.

Scenarios currently cover:

- normal
- running
- main failure
- mixed Enterprise/GitHub contexts
- light/dark appearances

Snapshots use an explicit, deterministic light/dark backdrop. This keeps transparent/glass content readable in arbitrary artifact viewers and gives macOS 26 glass/material effects a stable surface to composite against.

The PR workflow checks out both the PR and `main`, renders both versions on the same macOS/Xcode runner, then generates an HTML report with:

- Before image
- After image
- opacity/overlay slider
- NEW / REMOVED / CHANGED / UNCHANGED state based on SHA-256 of rendered PNGs

No binary baseline needs to be manually committed. The canonical baseline is the code on `main` rendered in the same job.

## Bootstrap behavior

The first PR cannot render a `main` baseline because the renderer does not exist on `main` yet. Its candidate images are reported as `NEW`. After the bootstrap PR is merged, later PRs get real before/after comparison automatically.

## Why the initial report does not fail on a changed pixel

The first goal is reviewability and renderer stability. macOS rasterization tolerance needs empirical data before a pixel/perceptual threshold becomes a required check. Once stable, a later ADR can introduce a blocking threshold or a fixed self-hosted Mac visual runner.

## Toolchain lanes

The required lane is pinned to Xcode 26.6 / Swift 6.3 on `macos-26`. A separate scheduled `xcode-27` public-preview canary is intentionally non-blocking. Preview runner failures are compatibility signals, never release or merge gates.

## Future layers

- XCUITest smoke flow: click status item, open popover/settings
- artifact screenshots from full app
- accessibility variants (increased contrast/reduced transparency)
- fixed self-hosted Mac only if GitHub-hosted raster differences become materially flaky
- optional perceptual image diff after tolerance is calibrated

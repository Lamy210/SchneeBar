# Companion asset and menu renderer slice C2a/C3a

Status: independent implementation draft only. ADR-0004, reuse rights, app wiring and real-device acceptance are still gates. No Runner artwork, source or tests copied. Synthetic CoreGraphics fixtures only.

## Asset admission

The decoder accepts only existing in-memory Data, not arbitrary URL, archive, network or filesystem. Reject empty payload or >32 MiB before ImageIO. Identify content from ImageIO UTI, allow PNG (including APNG), GIF and WebP; reject other formats. Accept 1..120 frames; preflight all metadata (width/height 1..4096, aggregate <=16,000,000 pixels) before explicit frame decode. Recheck decoded dimensions and aggregate, normalize retained image into 8-bit RGBA premultiplied bitmap. Return only a complete clip or throw; no partial persistence. Default missing/nonpositive/nonfinite duration 0.1s; positive timings clamp to 0.02..10s before constructing bounded CompanionClip. Explicit policy difference from arbitrary source schedules; ratios preserved after normalization, not necessarily original invalid metadata. ImageIO support for APNG/WebP and partial-compositing behavior must be tested on supported macOS; no claim of full format parity. Size ceilings bound application-owned decoded pixel storage to approximately 64 MB per clip excluding allocator overhead, transient source/decoder allocations and copies; not a hard process RSS limit. File acquisition must bound bytes before allocating Data; this API cannot bound a caller's earlier allocation. Do not invoke on the UI path for user imports without separately reviewed background decoding, cancellation/publication fence and catalog-wide budget.

## Renderer

An isolated MainActor AppKit driver consumes validated clip, scales menu image logical size to fit 18pt while preserving aspect ratio (provisional design value), emits frames to a caller-owned surface and creates no status item. Uses cursor token and per-schedule identity, one pending cancellable task. Identical clip is a no-op; rate preserves frame index; reduce motion cancels progression and freezes current frame; one-frame clip has no schedule; stop clears owned presentation once and cancels timers. Caller must wire system Reduce Motion, render ownership and restoration of existing status button, sleep/wake and configuration generation. This slice does NOT connect to production app, add a setting, subscribe Companion CPU, persist user assets or implement Desktop/Focus. No second NSStatusItem, no credential access.

## Remaining C2/C3 scope

- C2b: validate and copy bounded file input using descriptor-based no-follow and regular-file checks; manifest version, canonical path confinement, source/destination symlink and TOCTOU tests, atomic staging, catalog-wide budget, import cancellation and rollback. PNG sequence, sprite sheet, pack export/build and fallback fixtures. No archive extraction until separate threat review.
- C2c: actual APNG/WebP animated fixtures, malformed/truncated image and excessive metadata/decode corpus, decoder memory and compositing verification. Source compatibility ledger.
- C3b: explicit opt-in settings and one app-owned coordinator sharing CPU service, no hidden polling, real status item image restore, Reduce Motion and accessible text. Render only validated assets; use independent original fallback. Desktop surface and Productivity follow separately.
- Tests in C2a/C3a: generated PNG and animated GIF, size/type limits, dimension/cumulative admission, idempotent static frame rendering/clear. Timing cursor tests from C1b cover stale/duplicate ticks; add deterministic renderer scheduler and cancellation integration fixtures before connecting actual UI. Verify new targets are exercised in macOS CI. No completion claim for C2/C3 or #370.

### Deterministic renderer verification

An internal injected scheduler can deliberately invoke cancelled/duplicate callbacks. The new animated GIF fixture exercises normal advancement, duplicate rejection, speed changes preserving frame, Reduce Motion freeze/resume and stop with late callback. The test is independent of real-time sleeps and does not replace macOS integration or actual power measurement.

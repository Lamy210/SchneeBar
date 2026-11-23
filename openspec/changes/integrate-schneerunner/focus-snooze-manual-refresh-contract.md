# E3w: Manual refresh and fail-closed recovery of Snooze management

## Background
The standalone E3u/E3v Snooze management panel loads its candidates on initial appearance only. If that read fails, stale actionable rows are removed but the user cannot retry without dismissing the view. A separate owner may also claim or acknowledge a Snooze while the panel remains visible.

## Scope and contract
- Add an explicit, keyboard-accessible "Refresh Snoozes" control in the standalone `SchneeBarFocusFeature` management panel. It calls the existing `FocusSnoozeManagementCoordinator.load()` API for a fresh validated durable snapshot. Do not invent authorization from cached UI rows.
- Refresh is always offered, including after a failed initial load; it is disabled while a load or cancellation is in progress, avoiding double submission. A refreshing indicator is shown when previous content is present. On manual refresh, invalidate any pending destructive confirmation before awaiting I/O.
- On successful refresh, replace the entire displayed set from the freshly loaded snapshot; therefore an externally claimed Snooze changes from `pending` to `unacknowledgedOutbox`, acknowledged/disabled entries disappear, and renames propagate while exact ticket identities remain unchanged. Manual refresh is read-only and must not write the Outbox.
- If the read fails, hide all previously actionable rows, clear any confirmation, provide neutral feedback and leave the Refresh control available for another attempt. Do not display a success message or assume that a notification was cancelled.
- Preserve E3t exact-ticket revalidation for the actual destructive action and E3v confirmation; no background polling, OS notification operation, permission prompts, disk schema changes, shipping App dependency, logging of private titles or external providers.
- This is an isolated developer-preview UI; manual keyboard navigation and VoiceOver acceptance on physical macOS remain separate verification gates.

## Verification
Four Swift Testing regressions exercise the same actor's read-only refresh after an external claim into the Outbox, external ACK/disable, an external rename, and a non-file backing URL failure. These tests verify the coordinator's reloading semantics; native UI button/VoiceOver behavior still requires manual validation.
Require latest-head macOS Build/Test (including all four new tests), Visual Regression, strict OpenSpec, scope-limited diff, no merge conflicts and zero unresolved review threads. CodeQL skipped is not PASS. Merge to `integration/schneerunner` only after all gates; #396 main promotion remains blocked.

# E3x: Privacy-preserving Snooze status counts in standalone UI

## Motivation
E3s–E3w introduced a standalone read-only Snooze view and an explicitly confirmed pending-only management view. Each can present up to the bounded set of Snooze entries and Outbox intents. Without aggregate status, users must scan every row to see whether notification submission is still uncertain.

## Scope and guarantees
- Add `FocusSnoozeStatusSummary`, a pure, bounded projection computed **only** from an already loaded `[FocusSnoozeStatusRow]`. It exposes precisely pending count, unacknowledged-Outbox count, their sum and a boolean warning flag. The summary contains no titles, UUIDs, deadlines, imported data, or OS evidence.
- Count `pending` and `unacknowledgedOutbox` separately. The unacknowledged count MUST NOT be called sent, delivered, failed or cancellable: an OS notification may already have been accepted without a persisted ACK.
- Reuse `FocusSnoozeStatusSummaryView` from both standalone read-only and management views. If no candidates are present, suppress the informational summary; the preexisting empty state remains. For an unacknowledged count above zero, prominently display that such requests may have reached macOS and cannot be cancelled through this view. Combined accessibility phrasing must distinguish both counts.
- Management summary is derived from the currently displayed rows, so it updates after a committed cancellation, an explicit refresh and a failure that hides stale rows. It must not create an extra store read, a clock, timer, UserNotifications call, permission prompt, or write. Existing confirmation/strict-ticket cancellation and status sorting remain unchanged.
- No shipping-app wiring, storage schema change, notification dispatch/retract, false success claim, copy of private reminder titles into telemetry, or PR #396 main promotion.

## Verification and gates
- Empty rows yield both counts zero and no ambiguous warning; pending-only rows never imply unconfirmed OS acceptance.
- Mixed rows count correctly, and changing titles/identifiers/order does not affect the summary.
- Constructing the UI summary view is side-effect-free. An actual persisted pending→claimed Outbox→ACK sequence must produce counts 1/0, 0/1, then 0/0 without mutating the file on read; the underlying exact-ticket cancellation regression suite must remain green.
- Latest-head native macOS Build/Test must pass six new Swift Testing cases; Visual Regression, strict OpenSpec, the planned 5-file diff, mergeability and zero unresolved review threads are mandatory for integration. CodeQL skipped is not success. Real macOS VoiceOver and contrast validation still require manual acceptance.

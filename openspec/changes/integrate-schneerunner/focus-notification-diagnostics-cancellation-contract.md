# E4d: fail-closed cancellation for developer notification diagnostics

## Context
The E4a/E4b standalone developer-only notification diagnostics panel starts an asynchronous read when the SwiftUI view appears or when an operator selects Refresh. Dismissing the view cancels the SwiftUI task, but existing actor calls to load the local Outbox and macOS notification identifier lists do not automatically throw on cancellation. A completed but cancelled request can incorrectly publish outdated counts after the user has navigated away.

## Contract
- `FocusReminderNotificationDiagnosticsReader.load(maximumEvidenceCount:)` checks its own task cancellation before the first store read, after the first store read, after the bounded macOS evidence inspection, and after the last durable snapshot read and drift comparison. A cancelled task must throw the standard `CancellationError` and never return a diagnostic summary.
- Maintain the existing E3z durable snapshot comparison and E3aa permission drift guard. Cancellation is not evidence of success, not a request to retry, and not an exception to evidence bounds. The two macOS lists remain non-atomic. Cancellation checks narrow the window; they do not guarantee that no OS reads occur after a cancellation event or that OS observations are atomic.
- `FocusNotificationDiagnosticsViewState.refresh()` handles `CancellationError` separately from validation/IO errors. Clear old diagnostic counts, clear error feedback, and reset `isLoading` without displaying misleading “could not be verified” messaging on ordinary view dismissal. Other failures still show the neutral retry message.
- No OS notification submission, removal, automatic acknowledgement, resend, permission prompt, disk mutation, background polling, timers, raw IDs or titles, logging of private user content, production app wiring, signing or distribution.
- This change stacks on E4c PR #495 until E4c is merged, then must be rebased onto the latest `integration/schneerunner` with only its actual changes. PR #396 remains Draft and is not merged into main.

## Verification
- Inject a controllable notification-center port that suspends the first authorization read. Cancel a diagnostic reader task before releasing that read. The reader must throw `CancellationError`, never return counts, create no Outbox file, and invoke no add/remove.
- Inject the same suspended-first-authorization pattern into the view-state refresh. Cancel the refresh and release the port. The view state must finish with `isLoading == false`, `diagnostics == nil` and `errorMessage == nil`, and no disk/OS mutation.
- The test stubs must not stall when the real E3aa gateway performs its second authorization read; existing bounded evidence, permission drift, durable drift, E4a view and E4b refresh regressions must remain green.
- Require exact-HEAD macOS native Build/Test with both new test functions PASS, Visual Regression, OpenSpec strict, and after Ready the actual Swift CodeQL analysis success. Compare only the expected five files, no behind commits, merge conflicts or unresolved reviews. Do not use a skipped CodeQL result as success.

## Out of scope
Not a transaction, not proof of notification delivery, no production UI connection, permission change, recovery ACK, Runner decommission, asset-rights/ADR bypass, real-Mac acceptance bypass or PR #396 promotion.

# E3t: atomic pending-only Snooze cancellation for future UI

## Problem
E3q's general `apply(.cancelSnooze(ticketID:))` intentionally supports revoking an **unacknowledged** Snooze Outbox intent. That intent may already have been accepted by the OS before the local ACK; therefore it is unsafe to expose this broad cancellation command as an ordinary "cancel scheduled Snooze" UI action. E3r's preview is read-only, and E3s's isolated UI has no action.

## Contract
- Introduce `FocusReminderCollectionStore.cancelPendingSnooze(reminderID:ticketID:)`. Its only positive path requires an existing currently pending Snooze in the named reminder, with the **exact ticket ID**. The method reads, revalidates, mutates and persists within the collection actor without suspension; it does **not** trust a prior UI snapshot.
- No matching reminder -> `staleReminder`. Missing, foreign, claimed, cancelled or previously ACKed ticket -> `FocusReminderState.StateError.staleTicket`. Any unexpected Snooze Outbox record with the same reminder and ticket must fail closed with `invalidOutbox`; never remove or ACK any Outbox record.
- On success, revoke the pending Snooze only; retain original occurrence cursor, recurring schedule, enabled status, reminder title and other reminders. Never grant a new Snooze opportunity. Persist with the existing bounded atomic replacement. If the write fails, no success is returned and the previous bytes/ticket remain eligible for retry.
- No call to `UserNotifications`, no permission prompts, dispatch, notification cancellation, UI button, new on-disk format, new file owner or cross-process fencing. Existing broad cancellation remains available for a separately authorized, evidence-based recovery workflow; do not silently repurpose it for UI.

## Tests
- Reload/restart then cancel exact pending Snooze; state and recurrence unchanged, replay rejected.
- Snooze already claimed to an unacknowledged Outbox, then acknowledged: both cases reject and preserve queue semantics.
- Wrong reminder ID, foreign ticket ID, another reminder's unaffected ticket and targeted cancellation.
- Injected write failure preserves exact bytes and allows retry.
- Before integrating with UI, require current-head macOS native Build/Test and all four new Swift Testing tests, Visual Regression, strict OpenSpec and review/mergeability checks. CodeQL skipped is not PASS.

## Still excluded
Shipping app integration, interactive SwiftUI controls, OS cancellation or delivery certainty, live VoiceOver testing, process-level fencing, rights/ADR-0004/real-Mac acceptance, signing or distribution, and PR #396 promotion to main.

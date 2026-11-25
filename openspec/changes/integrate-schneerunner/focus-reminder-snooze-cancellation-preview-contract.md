# E3r: read-only Snooze cancellation candidates for a future UI

## Purpose
The prior E3q cancellation command is exact-ticket-bound and changes durable state. The UI must not confuse a pending Snooze with one already claimed to an Outbox that may have reached UserNotifications. Provide a deterministic, read-only projection from one validated collection snapshot; this is not an action authorization.

## Contract
- `FocusReminderCollectionStore.Snapshot.snoozeCancellationCandidates()` returns each eligible native/enabled reminder Snooze, sorted by absolute deadline, reminder UUID, then ticket UUID. An optional reminder ID filter returns the same scoped subset.
- A pending Snooze is labelled `pending`; an unacknowledged `kind=snooze` Outbox intent is labelled `unacknowledgedOutbox`, expressly **not** "unsent". The OS may already have accepted the notification before the local ACK. If an inconsistent supplied snapshot contains both forms of the same ticket, prefer the more conservative queued phase.
- Regular Outbox entries, disabled/imported reminders and reminders without a Snooze produce no candidates. When the OS adapter has acknowledged and removed an Outbox item, it must not reappear as a cancellation candidate.
- No wall-clock eligibility guesses, filesystem access, API calls, OS inspection, mutation, acknowledgement, permission prompt or automatic notification cancellation. The caller must reload and revalidate exact ticket ownership through the E3q command before acting; a stale UI candidate can fail closed. OS request removal, if needed, is a separate approved protocol.
- Do not alter persisted schemas, the single-owner assumption, resource limits, shipping App dependencies, or rights/release gates.

## Tests and gates
Four deterministic Swift Testing regressions cover pending/scoped/read-only projection; queued (possibly submitted) versus acknowledged differentiation across restart; deterministic ordering with mixed phases; and suppression of regular/disabled entries. Native macOS Build/Test, Visual Regression and OpenSpec strict must pass on the exact PR HEAD, and there must be no unresolved review threads before merging into `integration/schneerunner` only. CodeQL skipped is not success.

## Deferred
UI wiring, accessible action labelling, notification ownership/cancel-or-reconcile protocol, real-device validation and promotion of #396 to main remain blocked behind their existing independent acceptance gates.

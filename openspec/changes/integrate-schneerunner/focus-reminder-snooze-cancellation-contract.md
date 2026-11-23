# E3f: cancel a pending or unacknowledged snooze by exact ticket identity

## Motivation
An enabled native reminder can create a one-time Snooze ticket and subsequently claim it into a durable notification outbox. The current domain offers no explicit dismissal of a pending Snooze. Simply disabling or deleting a reminder also discards unrelated scheduling state. The OS notification adapter is not yet wired into the shipping app; this change is **local intent cancellation**, not notification withdrawal.

## Contract
- Add `FocusReminderStore.Command.cancelSnooze(ticketID:)` and matching `FocusReminderState.cancelSnooze(ticketID:)`. Only the exact current pending ticket may be cancelled; wrong, already consumed or replayed ticket IDs return `staleTicket`. The regular occurrence cursor is preserved and the Snooze opportunity is not reopened. Do not modify recurrence, enabled state or imported-reminder policy.
- In `FocusReminderCollectionStore`, `cancelSnooze(ticketID:)` also revokes an exact **unacknowledged** `kind == .snooze` outbox intent for the same reminder, even if its Snooze ticket has already been claimed from state. Remove only the matching reminder/kind/ticket record. Preserve all other outbox records and reminder entries.
- Mutation and outbox removal are committed in the same bounded atomic snapshot replacement. If write fails, neither state nor outbox changes. No success result may be emitted before persistence succeeds.
- Repeated cancellation and foreign/stale ticket IDs fail closed, never silently cancelling a newer ticket. Acknowledged notifications no longer in the outbox cannot be retracted through this API and must reject cancellation. The caller must separately coordinate actual OS notifications if/when the adapter is integrated.
- Keep v1/v2 persisted formats, size/capacity ceilings, single-owner assumption and unsigned nonshipping integration branch unchanged; no new entitlement, permission prompt, notification dispatch or data migration.

## Verification
- Restart/reload and cancel exact pending Snooze; wrong ID, replayed cancel and stale claim fail; regular recurrence cursor unchanged.
- Claim a Snooze into durable outbox, cancel exact queued ticket, then reject stale acknowledgment/repeated cancel.
- Inject file-write failure for both pending and queued cases; byte-for-byte backing data and retryability preserved.
- Verify corresponding single-reminder store cancellation and no renewed Snooze opportunity.
- Run native macOS Build/Test on exact HEAD and check four added Swift Testing test names in the CI job log, plus Visual Regression and strict OpenSpec. CodeQL skipped is not a pass.

## Deferred
Outbox-accepted/acknowledged notification withdrawal, OS cancellation request identity mapping, actual display/authorization, multi-process fencing, timezone and real-device user acceptance, ADR-0004/assets rights and #396 main promotion all remain independent release gates.

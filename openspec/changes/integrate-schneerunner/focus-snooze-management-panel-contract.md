# E3u: explicit pending-only Snooze management UI

## Background
E3q's broad cancel action may remove an Outbox intent that the OS has already accepted. E3r provides safe read-only candidate projection, E3s adds a noninteractive SwiftUI status panel, and E3t supplies `cancelPendingSnooze(reminderID:ticketID:)`, which commits only a currently unclaimed pending Snooze after fresh durable validation.

## Contract
- Add a separate `FocusSnoozeManagementCoordinator` actor to `SchneeBarFocusFeature`, holding a supplied `FocusReminderCollectionStore`. `load()` creates a status projection from one fresh validated snapshot; `cancelPending(reminderID:ticketID:)` delegates to the E3t pending-only cancellation and returns a projection from its **committed** snapshot. No broad `apply(.cancelSnooze)` is available through this owner.
- Add an **isolated developer-only** `FocusSnoozeManagementPanel`. It loads from the coordinator on appearance. Only `phase == .pending` rows show a keyboard-accessible `Remove pending Snooze` action. `unacknowledgedOutbox` rows have **no action** and retain an explicit warning that OS submission may already have occurred. Every action passes the exact reminder/ticket identity to the owner, which must re-read durable state before committing. An outdated row fails closed.
- The UI must prevent double submission during a local mutation, report success only after the store commit, refresh its display from the committed snapshot, and on failures reload or hide stale actionable rows. Feedback must say only that local pending schedule was changed; never claim OS delivery was recalled or canceled.
- Include an accessible label on the action including the reminder title, use locale-aware deadline rendering, support many rows via scrolling and dynamic text, and never display internal ticket IDs or content from other providers. State handling must use Swift 6 actor-safe boundaries.
- This is a separately testable framework component only. Do not connect to the shipping menu bar, request notification permission, dispatch/remove OS alerts, change storage formats or lifecycle ownership, or bypass ADR/assets/performance/rollback gates.

## Verification
- Empty read does not create a backing file; cancellation returns the updated projection preserving unrelated reminders.
- A stale UI projection cannot cancel a ticket that has already moved to Outbox; queued/acknowledged states are handled without lying about OS acceptance.
- Foreign IDs, repeated actions, and invalid backing-file persistence attempts must fail closed without modifying existing persistent bytes or returning success. Injected write-failure coverage remains in E3t persistence tests; the public store initializer does not permit write-hook injection from the feature test module.
- Constructing the view itself is side-effect-free. Native Build/Test executes all six added Swift Testing tests; Visual Regression and OpenSpec strict must succeed on the exact HEAD. Treat CodeQL skipped as skipped.
- This feature is based on the E3t branch (#485); do not merge it independently to `integration/schneerunner` before E3t is integrated and its native CI revalidated.

## Exclusions
Real macOS screen-reader and keyboard acceptance, OS notification cancellation/ownership evidence, UI integration into SchneeBarApp, cross-process lease, signing and distribution, material rights and #396 main promotion remain separate.

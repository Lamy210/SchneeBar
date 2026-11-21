# E3k draft: OS notification evidence adapter and shared Focus namespace

## Baseline
Requires merged #451/#453/#452. The existing Focus notification module is an isolated native macOS 15+ target, still **not connected** to the shipping app's lifecycle. #453 introduced a pure evidence reconciliation function; until this change there was no adapter to fetch OS pending/delivered lists. The adapter reuses the #453 canonical `FocusReminderNotificationIdentity` parser/formatter instead of maintaining a second prefix implementation.

## Port and permissions
Add two `FocusReminderNotificationCenterPort` read operations: current pending request identifiers and current delivered notification identifiers, from the local app-owned `UNUserNotificationCenter` only. The real port uses Swift async `pendingNotificationRequests()` and `deliveredNotifications()`. Return explicit authorization status alongside both arrays; `denied`, `notDetermined` and unsupported are NOT converted to success, and an empty result in those states does **not** mean a notification was never presented. This is read-only; it must never request authorization, register, cancel or ACK during observation.

## Bounds, consistency and authority
`observe(maximumEvidenceCount:)` requires a bound in 1...65536, default 2048. Fail closed on over-limit pending, or on pending + delivered exceeding limit. Check before reconciling; do not silently truncate evidence or emit a partial success. The two OS reads are sequential and **not atomic**; evidence may be stale or incomplete even when authorized. This is suitable for an operator/developer reconciliation view, not automatic proof of non-delivery. The `inspect(snapshot:)` helper calls #453's pure reconciliation and reports both the exact OS authorization/evidence and resulting categories.

Only exact canonical Focus identifiers are eligible for potential Focus-only removal. Noncanonical prefixed strings, GitHub recovery or Runner identifiers are never passed into the real OS cancellation calls. No side effects are allowed in `inspect`. A separate future coordinator must serialize all submission and cancellation with durable ownership, reconcile after awaits and handle ambiguous absent OS evidence without blindly resubmitting.

## Tests
Inject a fake actor center. Verify dedup/foreign separation by #453, observed/missing/untracked results and authorization reporting, no mutation/no ACK, no add/remove, duplicate lists, invalid and overflow evidence bounds. Existing gateway tests and real macOS CI/Visual/OpenSpec are required before merge to `integration/schneerunner`. App notification wiring, handoff, OS-reported-delivery guarantees, missing OS evidence policy, UI, crash recovery, rights and main promotion remain gated by #396.

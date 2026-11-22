# E3o draft: fail-closed OS evidence recheck before durable notification ACK

## Motivation
`recoverOnce()` currently performs one non-atomic OS inspection, then performs a durable ACK for observed Outbox requests. Mac notification permission or OS pending/delivered requests can change while the actor is suspended between the inspection and the store write.

## Requirements
- The initial inspection remains read-only. When its authorization is `authorized` or `provisional` **and** its candidate ACK set is nonempty, perform another independent read-only OS inspection of the same validated Outbox snapshot **immediately before** the durable store CAS.
- Both inspections must agree on the exact authorization enum and the set of Outbox **candidate IDs** observed in pending/delivered OS snapshots. The order of results and unrelated application identifiers must not affect this comparison.
- If authorization changes or any candidate vanishes/appears, throw `evidenceChangedDuringRecovery` without ACK, OS add, OS remove, permission prompt or external side effects. The caller can request another read-only preview.
- If the second inspection raises an overflow or OS error, do not persist ACK.
- After a successful second inspection, acknowledge only its observed full Outbox records, subject to the persistence actor's existing exact-record compare-and-swap; any concurrent disable, delete, rule-edit or write error must still fail the entire batch.
- When no actionable initial candidate exists, return the existing report with no extra inspection or durable mutation. Permission denied/unknown remains manual-only.

## Non-guarantees
This additional check **reduces** a race window but cannot make separate UserNotifications queries and file writes atomic. It cannot establish that a user saw a notification. The shipping UI, dispatch/retry, confirmation, notification ownership and real-device validation are still gated by #396.

## Verification
- Deterministic injected port: OS permission changes from authorized to denied between the two inspections -> explicit error, queue intact, no side effects.
- OS request disappears between inspections -> explicit error, queue intact, no side effects.
- Both inspections are identical -> one ACK, queue empty, exactly two reads of authorization and pending identifiers.
- Existing tests for partial ACK, disabled reminders, absent evidence, non-authorized status, OS overflow and preview remain passing.
- Merge only to `integration/schneerunner` after macOS CI, Visual Regression, OpenSpec strict and review checks pass.

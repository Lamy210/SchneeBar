# E3p draft: single-snapshot read-only recovery triage

## Purpose
Operators need to see both the OS-evidence recovery preview (E3m) and durable Outbox pressure/age diagnostics (E3n) without presenting contradictory queue counts produced by two independent file loads. Add an explicit read-only boundary that uses **one validated durable `FocusReminderCollectionStore.Snapshot`** for both calculations.

## Contract
- `FocusReminderRecoveryUnifiedTriage.inspectOnce(at:agedAfter:maximumEvidenceCount:)` loads the durable store once and computes `outboxBacklogDiagnostics` from that snapshot.
- Reconcile UserNotifications evidence **against that same snapshot**, producing a `FocusReminderAcceptedRequestRecoveryPreview` with identical authorization and candidate/manual/untracked/ignored semantics as E3m.
- Return observation time, recovery preview and backlog aggregate. `report.preview.queuedOutboxCount == report.backlog.queuedCount` is invariant.
- Invalid/nonfinite observation time or invalid age threshold must fail before any OS inspection or mutation.
- OS pending/delivered overflow, malformed backing store or other failures must return an error, not a partial report.
- No notification add/remove, permission prompt, Outbox ACK/retry, file write, secret, title or identifier disclosures. No permission to automatically invoke recovery.

## Limitations
A durable snapshot can become stale immediately after read; pending and delivered OS snapshots are non-atomic. An ACK requires a fresh explicit `recoverOnce` and the latest exact-record CAS; E3o further rechecks OS evidence. Aged records and a lack of OS evidence are NOT authorization to send or acknowledge notifications.

This developer-only module does not wire into the shipping UI, change live notification ownership with SchneeRunner, or relax the uncompleted #396 ADR-0004/rights/real-Mac/distribution/performance gates.

## Acceptance / tests
- macOS Swift Testing 4 cases: one snapshot consistency (one observed and one missing with unrelated OS IDs), denied permission, invalid time/age parameters with no OS queries, evidence overflow with unchanged durable bytes.
- Confirm macOS Build/Test, Visual Regression and OpenSpec strict on exact PR head, no unresolved reviews.
- Merge to `integration/schneerunner` only; no `main` promotion.

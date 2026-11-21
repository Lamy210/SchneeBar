# E3h draft: bounded, explicit outbox replay policy

## Objective
Provide a deterministic, read-only replay plan for durable E3g outbox records. OS delivery and permission side effects are deliberately out of scope. Reading or planning cannot consume, acknowledge, remove or mutate any record. A dispatching caller must use the record's stable UUID as its OS request idempotency key and re-read authoritative state before side effects. No exactly-once notification guarantees.

## Selection
For a caller-supplied valid absolute time, partition the outbox into:
- `ready`: claimedAt <= now and (now - deadline) <= maxLateness, sorted by original deadline then regular before Snooze then reminder UUID then record UUID, limited to maxBatchSize.
- `heldForClock`: claimedAt > now (e.g. clock rollback), even if original deadline is older than now; do not deliver until a valid later time.
- `needsRecovery`: claimedAt <= now but lateness strictly exceeds policy; never auto-delete, silently acknowledge or auto-show a reminder hours late.
- `deferredReadyCount`: number of otherwise-ready records excluded solely by the per-tick batch cap. Owner must schedule further passes.

Provisional default maxBatchSize=16 (valid 1...128) and maxLateness=300 seconds (valid 0...86400 finite). These are **policy defaults for developer evaluation only**, not release or product decisions; collect missed-delivery user feedback before promoting. Invalid supplied time, batch or lateness must fail closed without side effects. Equal lateness boundary is eligible. Empty snapshot produces empty plan. No special treatment based on JSON insertion order.

## Failure modes / limits
- The plan does not implement retry scheduling/backoff, cross-process locking, OS authorization, request cancellation or durable OS acceptance tracking. Stable outbox IDs support eventual idempotent resubmission only when the adapter honors them.
- Snapshot staleness can occur during asynchronous submission; an OS adapter needs a cancellation/reconciliation protocol before shipping. A successful outbox ack means adapter acceptance only, not user delivery.
- Holding clock-rollback intents may require a later wake/recheck. Recovery records remain bounded by the existing 128-outbox limit and can block new claims; define operator/UI recovery before release.
- No change to version-2 on-disk schema, existing product App wiring, imported inactive records, ADR / rights / main-promotion criteria or signing.

## Acceptance tests
Swift Testing cases: bounded batches and backlog count; exact lateness cutoff; missed/clock rollback classification; deterministic regular-vs-Snooze ordering; disable and ack reflection; invalid time/batch/lateness failure; no change to persisted snapshot. Native macOS CI, Visual Regression and OpenSpec Validation must pass before merge to `integration/schneerunner`. This is not shipping acceptance.

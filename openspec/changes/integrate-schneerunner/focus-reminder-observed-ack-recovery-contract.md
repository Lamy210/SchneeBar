# E3l draft: durable observed-acceptance reconciliation

## Purpose and authority
Recover from the gap after `UNUserNotificationCenter.add` accepts a Focus reminder but before the corresponding durable Outbox ACK is persisted. OS observation of a canonical request in `pending` or `delivered` is *positive request-acceptance evidence only*. It never proves that the user saw the reminder. This contract is deliberately not a scheduler or automatic resubmitter.

The isolated `FocusReminderAcceptedRequestRecovery` actor exposes one **explicitly invoked** `recoverOnce` method. The shipping App target remains unconnected; no daemon, timer, prompt, login item or runtime hook is added. #454 supplies the evidence snapshots; #453 supplies the classification; #450 supplies the durable Outbox.

## Algorithm
1. Read the authoritative `FocusReminderCollectionStore` snapshot and collect an OS evidence snapshot via the injected gateway. Enforce maximum evidence count (default 2048) and canonical Focus ownership.
2. Only under `authorized` or `provisional` authorization, collect exactly those queued Outbox records whose Focus request IDs appear in pending/delivered. Denied, notDetermined and unsupported must never acknowledge.
3. Use `acknowledgeObserved(records:)` on the **same store actor**. Compare the complete immutable record for **every** observation against the latest on-disk Outbox inside a single actor-owned transaction. Reject duplicate IDs and all stale/revoked records. Either all observed records are removed in one atomic file replacement or none are; a write failure leaves them queued. An empty batch is read-only.
4. Preserve all unobserved Outbox records, reporting how many require explicit recovery judgment. Do not resend, delete, ACK or cancel absent records. Preserve OS-only untracked identifiers without deletion.
5. Return only status and aggregate counts (acknowledged / unobserved / untracked / ignored); do not log private titles or identifiers.

## Concurrent failure modes / non-guarantees
- After an async OS read, a user may disable/delete/replan a reminder. The store's exact-record comparison is the final authority. Stale/changed/removed records cause a fail-closed exception, **not** partial acknowledgement.
- This actor does not own all future app writes, cannot fence a separate process, and cannot atomically observe the OS. If the OS reports a stale ID that was already presented, this is only evidence an OS request existed, not delivery proof.
- An OS notification already accepted but later removed externally may be absent from both OS lists; such a record remains queued indefinitely until an explicit decision. This trades bounded-late delivery for avoiding duplicate alerts. The 128-record Outbox may eventually fill, requiring a separate reviewed recovery UI/policy.
- The current single-record `acknowledge(outboxID:)` remains available internally, but any future runtime auto-ACK should use exact evidence and a single app-owned coordinator. No automatic `submit`, repeated request, OS cancel/compensation, scheduling backoff or persistence schema change in this slice.
- `.atomic` file replacement does not prove fsync/power-loss durability. Historical OS delivery is not guaranteed observable. Apple notification permission can change between read and operation; this recovery path never requests it.

## Tests and gates
Use Swift Testing with injected OS actors and a private temp file for: positive evidence ACK (one and multiple), retry/read-only behavior, missing evidence retained without add, denied/notDetermined/unsupported fail closed, concurrent disable after the OS read leaving unrelated records intact, batch duplicate/stale records, full-record comparison, and failed atomic file write. Run macOS Build/Test, Visual Regression, OpenSpec; CodeQL skipped is not a security approval. Integration branch only after checks. No main promotion until #396 rights/ADR/real macOS device/owner cutover acceptance.

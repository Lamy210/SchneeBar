# E3n draft: privacy-preserving durable Outbox backlog diagnostics

## Scope and authority
The Focus reminder Outbox currently has a hard maximum of 128 entries. A missing OS request is ambiguous after a crash; it can have already been shown and then cleared by the OS. E3n provides **read-only** queue diagnostics, so future operator UI can show capacity pressure and clock regression without accidentally submitting, acknowledging or cancelling an item.

The diagnostics are computed solely from an already validated `FocusReminderCollectionStore.Snapshot`. No notification permission is requested, no OS state is read, and no persistent data is mutated.

## Diagnostic contract
- `outboxBacklogDiagnostics(at:agedAfter:)` returns queued count, free slots under the existing 128-entry bound, count of entries whose `claimedAt` is at least the caller-selected nonnegative threshold old, count of entries whose `claimedAt` is in the future relative to the supplied observation clock, and the oldest claim timestamp if any.
- Aged includes exact equality with the threshold. A future claim is **not** aged; a future timestamp indicates a clock-discontinuity symptom to investigate, **not** evidence that a reminder should be resubmitted.
- Reject nonfinite observation times and nonfinite or negative age thresholds. Do not return a partial/sanitized diagnostic for invalid inputs.
- Empty queues show 0 pending, 128 remaining and no oldest claim. At capacity, remaining slots are 0.
- Do not include reminder titles, OS identifiers, GitHub/Runner credentials or other user content.

## Non-guarantees and boundaries
- Age, capacity pressure and future timestamps are observability only. They do NOT authorize retry, notification submission, cancellation or Outbox ACK; missing OS evidence is never proof of non-delivery.
- This is a point-in-time snapshot; a separate process may mutate the Outbox. Cross-process locks, fsync/power-loss guarantees, manual recovery UI, automatic backoff and owner handoff remain outside this slice.
- The shipping app is not connected. No user-facing widget, listener, login item or notification is enabled.

## Verification gates
- macOS Swift Testing: empty queue, deterministic two-item age threshold including equality, future claim detection, invalid date/threshold fail-closed and byte-for-byte unchanged durable data.
- macOS CI Build/Test, Visual Regression and OpenSpec strict validation on the exact PR head.
- Merge only to `integration/schneerunner` after checks. Preserve #396's rights, ADR-0004, real Mac device, notification coexistence, performance, signing, distribution and `main` promotion gates.

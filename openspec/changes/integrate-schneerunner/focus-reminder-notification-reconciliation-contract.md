# E3j draft: crash-safe notification evidence reconciliation (read-only)

## Aim
Before wiring an Outbox sender, provide a deterministic reconciliation *view* that compares the durable Focus Outbox with an explicitly supplied snapshot of the same application's `UNUserNotificationCenter` pending and delivered request IDs. Neither this module nor the source of the evidence is automatically activated in the shipping app. No permission prompt, OS API call, acknowledgement, removal or resubmission occurs here.

## Namespacing and authority
- IDs follow the canonical `dev.lamy.schneebar.focus.<lowercase UUID>` format keyed by durable Outbox UUID, matching the proposed gateway in #452. Noncanonical case, malformed UUIDs, GitHub recovery IDs, other namespaces and Runner IDs are ignored; never issue cancellation against them.
- Evidence is bounded to 2048 supplied system identifiers by default, with a caller-validated 1...65536 maximum. On bound violation return an error rather than producing an incomplete report.
- Dedupe duplicate pending/delivered IDs; order Outbox records by deadline and Outbox UUID, unrelated owned identifiers lexically. Input ordering MUST NOT change the final report.

## Classification
- `observedInSystem`: a still-unacknowledged Outbox record whose namespaced UUID is listed in OS pending/delivered evidence. This only supports an *eventual* ACK after authoritative revalidation; it never proves user presentation.
- `missingSystemEvidence`: a durable Outbox record not listed in OS evidence. Absence can mean never submitted, presented then removed, externally cleared, or a stale observation. **Never automatically resend, ACK or delete based on absence alone**, or duplicate user-visible alerts can occur after an acceptance/ACK crash.
- `untrackedOwnedIdentifiers`: a canonical Focus ID listed in OS evidence but no longer in the live Outbox. It might be an already acknowledged delivered alert. Do not automatically cancel it.
- `ignoredIdentifierCount`: count of non-Focus/noncanonical identifiers; no details or secrets logged.

The authoritative Outbox remains the only source of unacknowledged intents. The result is a time-of-check snapshot only. The future single app-owned coordinator must serialize dispatch and cancellation, revalidate after async OS calls, decide unknown/permission-denied recovery, and persist acceptance/ACK safely. A prior OS-delivered ID being absent from the delivered list is not evidence that no notification occurred. This slice intentionally fails closed for ambiguous requests, potentially leaving blocked backlog until an explicit recovery policy is approved. The existing 128-entry Outbox limit is unchanged.

## Tests and release gates
New Swift Testing regressions: observed pending/delivered vs missing and untracked classification, duplicated and external identifier handling, deterministic ordering, post-ACK evidence classification, canonical namespace parsing and evidence bound rejection. Run macOS CI, OpenSpec and Visual; CodeQL skip does not count as evidence. Main promotion, real-device notification delivery and permission flows, source Runner handoff, ADR-0004 and legal/material approvals remain gated.

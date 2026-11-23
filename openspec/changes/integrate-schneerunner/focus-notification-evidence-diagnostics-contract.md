# E3y: read-only, privacy-preserving macOS notification evidence diagnostics

## Purpose
E3x only knows local pending and unacknowledged-Outbox counts; it must not infer whether macOS has accepted or displayed an alert. The existing `SchneeBarFocusNotifications` gateway already supports bounded, read-only authorization/pending/delivered inspection and conservative reconciliation. Introduce a typed, aggregate diagnostic for future host-owned troubleshooting without creating an OS effect or an automatic repair path.

## Scope and design
- Add `FocusReminderNotificationDiagnostics` in `SchneeBarFocusNotifications`, constructed from an existing `FocusReminderNotificationInspection`. Expose authorization, evidence quality, count of durable Outbox intents observed under the exact Focus namespace, count with no OS evidence, count of untracked owned identifiers, count of ignored/unowned/noncanonical identifiers, and an informational manual-review flag.
- Keep ALL request IDs, reminder IDs, titles, deadlines, raw OS identifiers, and user-entered information out of this aggregate type. Duplicate canonical OS identifiers in pending/delivered lists must count once, while ignored identifier count retains the reconciliation module's existing semantics.
- `authorizationRestricted` includes denied, notDetermined and unsupported. The `nonAtomicSnapshot` quality is used for authorized/provisional but explicitly DOES NOT prove user presentation, stable OS ownership, or cancellability. Absence of OS evidence must **never** imply safe retry or non-delivery; a listed request must **never** trigger an automatic ACK.
- Add `FocusReminderNotificationDiagnosticsReader` as an isolated actor requiring explicit `FocusReminderCollectionStore` and `FocusReminderNotificationGateway` injection. `load(maximumEvidenceCount:)` loads the durable snapshot and calls the existing bounded gateway `inspect`. No independent filesystem code, no permission prompts, `submit`, `cancel`, `acknowledge`, background polling, app integration, notification listener or process-global singleton.
- The durable Outbox read and OS evidence reads are NON-ATOMIC. Diagnostics are intentionally ephemeral: no result authorizes repair, replay, ACK, OS cancellation, permission changes or UI destructive actions. It must preserve the namespace isolation of SchneeRunner and GitHub recovery notifications.
- Invalid/unsafe file URLs fail before any OS read; corrupt or oversize files and exceeded OS evidence caps fail closed. Do not persist diagnostics or emit private identifiers to telemetry. No changes to Project.swift or app dependencies.

## Verification
- Empty store does not create a backing file or perform OS add/remove.
- Observed intent with duplicate OS IDs, unrelated GitHub identifier and untracked owned ID: accurate counts without leaking title, changing durable bytes or dispatching.
- Authorization denied or unknown: absence is inconclusive, not failed/delivered; no automatic retry or cleanup.
- Previously acknowledged Outbox request still listed by OS: untracked owned count only; no removal.
- Invalid evidence limit and evidence overflow reject before mutation; unsafe nonfile backing fails before OS reads.
- Authorized but missing evidence still requires manual review; empty authorized state need not.
- Native macOS CI Build/Test must execute all seven added Swift Testing tests, retain gateway/reconciliation regressions, and pass Visual Regression and strict OpenSpec. Compare exactly three files, no unresolved reviews or conflicts. CodeQL skipped is not PASS.
- A shipping UI integration and any human-facing remediation require separate specification, OS ownership/actor serialization, real-Mac acceptance, ADR-0004, privacy, rollout and rollback evidence. PR #396 MUST remain Draft and not be merged to main.

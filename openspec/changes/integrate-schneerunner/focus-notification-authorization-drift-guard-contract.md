# E3aa: fail-closed authorization drift while reading macOS notification evidence

## Context
E3y/E3z diagnostic counts use `FocusReminderNotificationGateway.observe()`, which checks notification authorization once before reading the non-atomic pending and delivered lists. If permission is revoked or newly granted during those awaits, the first status can be stale or misleading.

## Contract
- When `maximumEvidenceCount` is in range, observe the authorization status, pending identifiers, and delivered identifiers using the existing `FocusReminderNotificationCenterPort`. Preserve the current count limits and fail before additional calls if a list exceeds its limit.
- After both lists have passed the bounded-count checks, **sample authorization a second time**. If the result differs, throw `FocusReminderNotificationEvidenceError.authorizationChanged` without returning an evidence snapshot or reconciliation plan.
- If the two samples agree, retain the original authorization and identifier evidence as an explicit **non-atomic** snapshot. Equality is not proof of continuous authorization or lack of an ABA transition; permissions may change after return. Never interpret missing identifiers as non-delivery, retry permission to resend, or authorization for automatic ACK/cancel.
- The change is scoped to an existing read-only gateway: no permission prompt, notification add/remove, Outbox modification, external IDs, new timers or background polling, persistence schema, app wiring, or release change.
- Invalid `maximumEvidenceCount` rejects before any OS read; an oversized pending list rejects before delivered read or second authorization; an oversized delivered list rejects before the second authorization. Keep unrelated SchneeRunner and GitHub notification namespaces untouched.

## Verification
- A deterministic fake port returning `authorized → denied` must throw `authorizationChanged` after one pending and one delivered read; no OS mutation or store write.
- `denied → authorized` must also throw, rather than silently treating evidence as consistent.
- `authorized → authorized` returns the existing read-only reconciliation result, preserving original Outbox identity and avoiding submit/remove.
- Over-limit evidence must stop before the second authorization sample and preserve durable bytes.
- Update exact-port-call-count expectations for previously stable gateway, diagnostic, accepted-request recovery and unified-triage integration tests; regressions must remain green.
- Recovery action must preserve its existing domain-specific `FocusReminderAcceptedRequestRecoveryError.evidenceChangedDuringRecovery` failure contract when authorization changes inside the gateway inspection, and must never ACK on that path. The read-only gateway continues to throw the precise `FocusReminderNotificationEvidenceError.authorizationChanged` error.
- Require latest-head native macOS Build/Test with the four new tests and prior diagnostics/notification/recovery/triage regressions, Visual Regression, OpenSpec strict, conflict-free bounded diff, and zero unresolved review threads. When Ready, require a completed, successful Swift CodeQL analysis rather than treating Draft skipped as success.
- Integration target is `integration/schneerunner` only. PR #396 remains Draft; no shipping UI/OS effects, signing, distribution, Runner removal, ADR changes or real-Mac acceptance bypass.

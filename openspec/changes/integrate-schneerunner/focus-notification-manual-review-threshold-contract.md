# E4c: precise manual-review threshold for read-only notification diagnostics

## Context
The E3y `FocusReminderNotificationDiagnostics.requiresManualReview` currently becomes true whenever macOS notification authorization is restricted, even when SchneeBar has no durable Outbox records, no owned OS identifiers, and only unrelated app identifiers. The standalone E4a/E4b panel already shows a **separate** explicit limited-permission warning. Reporting manual recovery work with zero actionable Focus inventory creates operator alert fatigue and can imply that a notification must be retried.

## Contract
- `requiresManualReview` is **false** for restricted/unknown permission if the local Focus Outbox is empty, there are no untracked canonical Focus-owned OS identifiers, and no Focus Outbox was observed. Ignored identifiers belonging to other apps are not Focus manual-review tasks.
- Preserve `evidenceQuality == .authorizationRestricted` for `denied`, `notDetermined`, and `unsupported` regardless of inventory. The UI must still render the explicit restricted-permission / uncertain-delivery warning; no claims that permission is granted or delivery succeeded.
- `requiresManualReview` is **true** when any durable Focus record lacks OS evidence, when an untracked canonical owned OS identifier exists, or when a durable Focus record is OS-observed but authorization is restricted. Do not permit retry, ACK, deletion, or automatic cleanup from the flag.
- For authorized/provisional evidence with all durable Outbox records observed and no untracked owned identifiers, manual review remains false. OS evidence is non-atomic and never proof of delivery.
- This is a pure, privacy-preserving count-policy change. No raw identifiers, titles, permission prompts, notifications, file writes, schema changes, application wiring, background polling, signing, or distribution.

## Verification
- Denied authorization with an empty store: restricted quality retained, zero manual review and zero OS mutations.
- Not-determined authorization with only unrelated OS identifier: ignored ID count retained and no manual review.
- Unsupported authorization with untracked canonical Focus-owned identifier: manual review required, no OS cleanup.
- Denied authorization with an OS-observed durable Focus intent: manual review required even when `missingSystemEvidenceCount == 0`; no ACK or file changes.
- Existing diagnostics, read-only UI, recovery, and triage tests must remain green. Native macOS Build/Test must individually PASS all four new cases, plus Visual Regression and strict OpenSpec. On Ready require real Swift CodeQL success (skipped is not success). Changed files restricted to projection, tests, and this specification.
- PR targets `integration/schneerunner` only and must be rebased and retested if prior PR #494 merges first. PR #396 must stay Draft without a main merge.

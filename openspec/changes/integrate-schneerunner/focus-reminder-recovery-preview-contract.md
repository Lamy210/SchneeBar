# E3m draft: read-only Focus accepted-request recovery preview

## Purpose
Follow E3l (#455) with a non-mutating, operator-facing preview before any manual recovery policy or UI is approved. The shipping app remains unwired. This change does **not** authorize automatic dispatch, resubmission, cancellation, ACK, or exposure of notification titles.

## Contract
- \`FocusReminderAcceptedRequestRecovery.previewOnce(maximumEvidenceCount:)\` loads one durable Outbox snapshot and reads the OS's permission/pending/delivered identifier evidence using the existing bounded gateway.
- Return only aggregate counts: current queued Outbox, observed request IDs, candidates for a future explicit acknowledgement, records requiring manual review, untracked canonical Focus IDs, ignored foreign/noncanonical IDs, and notification authorization.
- An observed request is a candidate only when authorization is \`authorized\` or \`provisional\`. For \`denied\`, \`notDetermined\`, or \`unsupported\`, **every queued item** requires manual review and candidate ACK count is zero.
- This preview is explicitly **read-only**: no Outbox save, no OS add/remove, no prompt, no logging or exposure of private titles or identifiers. Repeated previews must be idempotent as long as inputs remain unchanged.
- Preserve existing evidence bounds and fail closed on overflow or unreadable data. Never truncate results or convert unknown OS state to a dispatch signal.

## Concurrency and limitation
The OS may change after any async call, and the Outbox may change after the snapshot. Preview is **not a token, lease, grant, or proof** that a later ACK will be valid. A future actual recovery attempt must independently re-read and revalidate authoritative Outbox and OS evidence via E3l. The two OS lists are not an atomic snapshot; absence is never proof of non-delivery.

## Tests and release gates
macOS Swift Testing must check repeated authorized preview, zero local/OS mutation, mismatched/foreign IDs, denied/notDetermined/unsupported authorization, and evidence overflow. Require CI Build/Test, Visual Regression and OpenSpec on the exact PR HEAD before integration into \`integration/schneerunner\`. Keep #396's real-device, ADR-0004, rights, Focus notification ownership/cutover, and main promotion gates unchanged.

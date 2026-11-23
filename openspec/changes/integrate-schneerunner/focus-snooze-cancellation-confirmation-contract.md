# E3v: explicit confirmation before pending-only Snooze cancellation

## Context
E3u supplies a developer-only UI in which a pending Snooze can be removed via one click. That is a destructive local scheduling action and should be protected from accidental activation, without implying an ability to recall a notification already accepted by macOS.

## Contract
- Add an explicit SwiftUI confirmation dialog between the user pressing "Remove pending Snooze" and calling the E3u coordinator. The initial button only saves a candidate for confirmation; it must not invoke the cancellation or change persistent state.
- The dialog must provide an explicit destructive action and a non-destructive "Keep Snooze" dismissal. Explain that the operation only removes a local pending schedule, not an OS-accepted notification. Dismissing or cancelling the dialog performs no mutation.
- The dialog must carry the exact reminder/ticket identity selected from the UI row. After confirmation, the existing E3u coordinator MUST still invoke E3t's fresh durable revalidation; a stale row moved to Outbox must be rejected. The UI's phase policy is presentation only, not authorization.
- Only `phase == .pending` may offer a confirmation action. An `unacknowledgedOutbox` row must not provide an action. Existing no-double-submit, failed-action reload, no false-success messaging, and fail-closed behavior remain.
- Preserve the separate `SchneeBarFocusFeature` boundary. Do not integrate shipping app UI, add OS notification dispatch/cancel, alter storage formats, trigger permission prompts, sign/distribute or merge #396 to main.

## Verification
- Pure policy tests confirm pending items can offer the action, while queued/outbox items cannot—even if IDs are identical—and reading policy leaves row unchanged.
- Existing E3u tests verify exact-ticket revalidation, stale claim/Outbox rejection, replay/foreign ID, and persistent failure semantics.
- macOS native Build/Test must run three added Swift Testing cases and all E3u regressions on the exact HEAD. Require Visual Regression, strict OpenSpec and unresolved review count 0 before merging. Manual keyboard/VoiceOver and dialog rendering acceptance remain a separate gate.
- This change depends on PR #486. Do not merge into integration until #486 is merged and #487 is compared against the updated integration base. CodeQL skipped is not PASS.

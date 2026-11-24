# E4b: testable fail-closed state for the standalone Focus diagnostics panel

## Goal
E4a's standalone developer-only notification evidence panel owns asynchronous refresh and error handling directly in its SwiftUI body. Extract this into a single explicit @MainActor observable state so that stale-result suppression and failure/retry recovery can be verified deterministically, without rendering the GUI.

## Contract
- Introduce `FocusNotificationDiagnosticsViewState: ObservableObject` in the existing `SchneeBarFocusFeature` target, with an explicitly injected `FocusReminderNotificationDiagnosticsReader`. State consists only of `diagnostics`, `isLoading` and neutral `errorMessage`. Do not store raw IDs, titles, provider data or OS receipts.
- A user-initiated or on-appearance `refresh()` rejects overlapping operations while `isLoading` is true. BEFORE awaiting the existing bounded reader, set `diagnostics = nil`, clear prior feedback, mark loading. Only on a successful validated read may counts become visible. On any read error (invalid file, E3z drift failure, OS evidence limit), leave counts hidden, show a non-sensitive retry message and reset loading.
- Manual refresh, initial appearance and error recovery use the same state path. The SwiftUI panel owns `@StateObject` and only binds to its published state; do not retain parallel `@State` copies of mutable diagnostics or add background polling. Show the same authorization, missing-evidence ambiguity, and not-proof-of-delivery disclaimers.
- No writes, ACK, resend, remove, permission requests, notification delivery, local timer, app wiring, storage schema changes or cross-process lock. This remains a developer-only panel.
- This branch stacks on PR #492. Only retarget to integration after #492 merges; confirm full diff and rerun exact-head CI on latest base. #396 stays Draft and never merges to main.

## Verification
- Empty initial read yields zero counts, no file, no OS mutation, and no loading/error residue.
- After a valid observation, corrupted local backing data causes a read failure: old counts are invalidated, a neutral retry message is visible, no private title is disclosed. Restoring the file and refreshing recovers cleanly.
- External Outbox ACK between refreshes changes the count from observed Outbox to untracked owned OS identifier without deleting any OS request.
- A controlled notification adapter that suspends on the **first** authorization sample must demonstrate that an overlapping `refresh()` returns without starting an additional OS inspection or any mutation, and that releasing the suspended request clears the loading state. Any second authorization sample (E3aa fail-closed permission-drift check) must not suspend again or deadlock the fixture. Accept one or two authorization samples for the complete successful inspection; exactly one may have started before release.
- All E4a existing read-only presentation tests remain green. Native macOS Build/Test and four new Swift Testing cases must pass, plus Visual Regression and OpenSpec strict on exact HEAD. On Ready, Swift CodeQL must be successful. Release Preview/Stable validations must remain green if run.
- Scope-limited files, conflict-free compare and zero unresolved reviews are mandatory. No signing, release or production app integration.

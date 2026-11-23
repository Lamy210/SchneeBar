# E3s: developer-only, read-only Snooze status panel

## Context
E3q introduces ticket-bound cancellation and E3r exposes a read-only projection of current Snooze tickets. Before exposing destructive or OS-related controls, reviewers need a standalone SwiftUI view that clearly distinguishes pending Snoozes from Outbox records whose OS submission status is ambiguous.

## Scope and architecture
- Add `SchneeBarFocusFeature`, an isolated macOS 15+ SwiftUI framework with an independent Swift Testing target. Depend only on `SchneeBarFocusPersistence`. Do not give the shipping `SchneeBarApp` target any new dependency or connect this view to a menu bar or notification.
- Create a pure `FocusSnoozeStatusPresentation(snapshot:)` using the existing E3r candidates, joining reminder titles from that **same validated snapshot**, preserving deadline/ID ordering and omitting inactive and acknowledged items. No additional file reads, wall-clock checks, OS evidence calls or state changes.
- Provide a read-only `FocusSnoozeStatusPanel` with a labelled empty state, locale-aware absolute deadline, user-visible reminder title, distinct warning for `unacknowledgedOutbox` ("may already be sent"), combined VoiceOver row labels and dynamic type-friendly text. Do **not** display raw UUIDs, include destructive buttons, infer actual delivery, or request notification authorization.
- The source view is for an independently testable preview only. It does not claim actual system rendering/VoiceOver accessibility has been manually accepted.
- Read-only views may become stale between snapshot creation and display. Future user actions must reload state and recheck the exact ticket through the E3q command and separately prove OS notification ownership/cancellation.
- No change to persistent formats, permission prompts, Runner lifecycle, asset rights, notification delivery, ACK/reconciliation, stable release or #396 promotion conditions.

## Verification
1. Empty snapshot yields empty model with no file creation; component can be initialized without writing.
2. Pending and unacknowledged Outbox statuses show distinct truthful labels, correct reminder titles and deterministic deadline order, and survive reload.
3. ACKed and disabled items vanish from the presentation.
4. Native macOS CI builds the new framework and test target, executes all four new Swift Testing tests; Visual Regression and OpenSpec strict are green on the exact HEAD. No unresolved reviews and no changed files outside this feature slice.

## Deferred gates
Actual app wiring, visual inspection on real macOS, VoiceOver keyboard/screen-reader acceptance, any interactive cancellation, OS request verification/removal, signing, third-party rights, ADR-0004, perf, rollback and #396 main promotion remain separately blocked.

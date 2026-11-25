# E4a: developer-only read-only Focus notification evidence panel

## Context and scope
E3y introduces a bounded, anonymous diagnostics projection from the durable Focus Outbox and non-atomic macOS pending/delivered identifiers. E3z adds a fail-closed local drift check. This slice exposes those facts to a developer in a standalone SwiftUI component, **not** in the shipping SchneeBar app.

## Design and requirements
- `SchneeBarFocusFeature` and its test target gain an explicit dependency on the existing `SchneeBarFocusNotifications` framework. Do not add that framework to the production `SchneeBarApp` target or change default launch, permissions, other providers, notifications or Runner lifecycle.
- `FocusNotificationDiagnosticsPanel` accepts an **injected** `FocusReminderNotificationDiagnosticsReader`. Construction only stores the reference; evidence reads require view appearance or an explicit user-initiated Refresh. No polling, background loop, implicit permission request, `submit`, `cancel`, `acknowledge` or persistent change.
- Read-only labels display only durable Outbox count, observed OS-list count, missing OS evidence count, untracked owned identifier count, ignored non-Focus identifiers, and authorization status. Titles, raw IDs, deadlines, OS details and other providers are never rendered or logged.
- Display that OS lists are **non-atomic** and **not proof of user delivery**, not permission to retry/ACK/cancel. For restricted permission, display an explicit uncertainty warning. Absence of OS evidence never implies failure. Untracked owned identifiers must not be automatically removed.
- A manual refresh clears previously shown diagnostic counts **before** awaiting the next read. Disable the Refresh control while busy; on failure (including drift check) leave stale numbers hidden, show neutral retry text and allow a subsequent user retry. Only a validated read may populate the display. The presentation is read-only, and must not expose destructive buttons.
- Preserve E3z snapshot drift failure where available, but recognize this view alone is not an OS/disk transaction or cross-process lock. UI acceptance and real VoiceOver/keyboard testing remain separate gates.

## Verification
1. View initialization with an injected reader creates no file or OS side effects.
2. Empty read is nonmutating and does not create the backing store.
3. Denied authorization with durable but missing OS record is reported as uncertain, preserving durable bytes, no send/remove.
4. Already ACKed Outbox record still visible in OS evidence is counted as untracked, never removed.
5. Unsafe non-file path rejects before notification mutation.
6. Native macOS Build/Test passes the five new Swift Testing cases and existing Focus feature/notifications regressions. Visual Regression, OpenSpec strict, and review/mergeability gates pass on exact HEAD. Treat CodeQL skipped as not run; Ready must trigger the configured Swift CodeQL analysis.
7. Separate PR to `integration/schneerunner` only; no promotion of PR #396 to main, permission changes, signing, distribution or Runner removal.

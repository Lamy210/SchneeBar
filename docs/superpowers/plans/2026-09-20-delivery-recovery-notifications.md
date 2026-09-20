# Delivery Recovery Notifications Implementation Plan

Date: 2026-09-20

Goal: Detect PR-scoped Workflow failure → success recovery from existing polling and emit privacy-minimized macOS local notifications with zero new GitHub requests.

Spec: `docs/superpowers/specs/2026-09-20-delivery-recovery-notifications-design.md`

## Global Constraints

- Recovery means Delivery/CI recovery, not GitHub connection re-authentication.
- Zero new GitHub HTTP requests.
- Existing Workflow polling limits unchanged.
- No background Deployment requests.
- No persistence in this slice.
- Only exactly-one-PR Workflow lanes.
- Cold data never emits historical recovery.
- System notification content contains no repository/account/branch/PR/workflow identity.
- No sound, badge, action, deep link, or remote push.
- Production changes follow TDD.

## Task 1 — Core Recovery Event

Files:
- Add `Sources/SchneeBarCore/DeliveryRecovery.swift`
- Add `Tests/SchneeBarCoreTests/DeliveryRecoveryTests.swift`

RED:
- construct and compare provider-neutral recovery event.

GREEN:
- opaque ID, repository/title/detail/destination/occurredAt.
- no provider DTO.

## Task 2 — Pure Workflow Recovery Tracker

Files:
- Add `Sources/SchneeBarGitHubActivityProvider/GitHubWorkflowRecoveryTracker.swift`
- Add `Tests/SchneeBarGitHubActivityProviderTests/GitHubWorkflowRecoveryTrackerTests.swift`

RED matrix:
- cold failure/success;
- failure → success;
- duplicate success;
- failure → running → success;
- failure → cancelled → success;
- same-run rerun recovery;
- newer failure re-arm;
- stale run;
- zero/multiple PR;
- lane isolation;
- raw SHA minimization.

GREEN:
- lane = workflowID + event + unique PR;
- use existing classification semantics;
- in-memory state only.

## Task 3 — Provider Integration / Replay Safety

Files:
- Modify `GitHubActivitySurfaceResult.swift`
- Modify `GitHubActivityProvider.swift`
- Modify provider tests.

RED:
- aggregate recovery events without new loader calls;
- cached reentrant load has zero recovery events;
- transient failure retains armed state;
- reset/prune clears state.

GREEN:
- internal Workflow success outcome carries current runs;
- update tracker sequentially after concurrent loads;
- cache result with recoveryEvents stripped.

## Task 4 — App Runtime Event Bridge

Files:
- Modify `GitHubConnectionsRuntimeModel.swift`
- Modify/add App tests.

RED:
- callback receives valid recovery once;
- stale profile result does not callback;
- callback is orthogonal to Activity item result.

GREEN:
- add `onDeliveryRecovery` callback;
- dispatch after result validity guard.

## Task 5 — Notification Center Port + Production Adapter

Files:
- Add `Sources/SchneeBarApp/DeliveryRecoveryNotifier.swift`
- Add `Tests/SchneeBarAppTests/DeliveryRecoveryNotifierTests.swift`

RED:
- permission-state matrix;
- provisional request;
- immediate generic notification;
- privacy copy;
- scheduling error isolation.

GREEN:
- wrap `UNUserNotificationCenter`;
- `prepareAuthorization()`;
- `deliver(_:)`;
- no action/userInfo/sound/badge.

## Task 6 — App Wiring

Files:
- Modify `Sources/SchneeBarApp/SchneeBarApp.swift`
- App tests where useful.

Implementation:
- AppDelegate owns notifier;
- async authorization preparation at launch;
- callback schedules delivery without blocking Activity refresh.

Acceptance:
- notification subsystem cannot mutate GitHub runtime state.

## Task 7 — Roadmap / Request Budget Regression

Files:
- Modify `docs/DEVELOPMENT_PLAN.md`
- Extend existing provider request-budget tests if needed.

Prove:
- same Workflow request count before/after recovery tracking;
- existing detailed Delivery = 12;
- history = 1;
- successful Workflow Inbox visibility unchanged.

No new Visual scenario is required because this slice adds no in-app UI. Visual Regression must remain unchanged/green.

## Task 8 — Exact-Head Gate

- CI success.
- Visual Regression success.
- CodeQL success.
- unresolved review threads = 0.
- requested-changes reviews = 0.
- mergeable = true.
- final diff confirms:
  - no GitHub client/endpoint change;
  - no polling-frequency/budget change;
  - no persistence;
  - no notification sensitive context.

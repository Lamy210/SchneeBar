# Standalone Delivery History / Navigation Implementation Plan

Date: 2026-09-20

Goal: Add a repository-scoped one-request Delivery history surface reachable from an already-loaded Workflow detail while preserving the existing detail snapshot and request budgets.

Spec: \`docs/superpowers/specs/2026-09-20-delivery-history-navigation-design.md\`

## Global Constraints

- Base implementation starts after the Phase 4 default-branch stack merged to main.
- Normal history open uses exactly one GitHub feature request.
- Fixed history query: completed, limit 20.
- No PR / commit association / Deployment / Environment / Jobs requests during history list loading.
- No background history polling.
- No persistence.
- Existing Activity detail 12-request ceiling remains unchanged.
- No new GitHub permission.
- Runtime inventory remains repository authority.
- Default-branch metadata is presentation-only.
- Production changes follow TDD.

## Task 1 — Core history contract

Files:
- Add: \`Sources/SchneeBarCore/DeliveryHistory.swift\`
- Add/modify Core tests.

RED:
- tests reference DeliveryHistoryEntry and DeliveryHistorySnapshot before production definitions.

GREEN:
- add provider-neutral entry/snapshot using ActivityDetailState.

Acceptance:
- no GitHub type in Core;
- opaque string ID;
- trusted URL remains optional.

## Task 2 — Pure GitHub history mapper

Files:
- Add: \`Sources/SchneeBarGitHubActivityProvider/GitHubDeliveryHistoryMapper.swift\`
- Add: \`Tests/SchneeBarGitHubActivityProviderTests/GitHubDeliveryHistoryMapperTests.swift\`

RED cases:
- success;
- failure/timed out;
- cancelled/skipped/neutral/stale → neutral;
- exact default branch;
- Main vs main mismatch;
- release/1.x remains visible;
- blank branch;
- deterministic updatedAt then ID ordering.

GREEN:
- map completed workflow runs into Core history.
- never expose SHA.

## Task 3 — Repository-scoped runtime history loader

Files:
- Add: \`Sources/SchneeBarApp/GitHubConnectionsRuntimeModel+DeliveryHistory.swift\`
- Add: \`Tests/SchneeBarAppTests/GitHubConnectionsRuntimeModelDeliveryHistoryTests.swift\`

RED:
- exact runtime repository expected;
- defaultBranch expected;
- query expected status=completed, limit=20;
- Actions unavailable expected zero loader calls;
- Actions unknown remains requestable;
- ambiguous repository match rejected.

GREEN:
- reuse repositoryAccess(profileID:fullName:);
- reuse profile canonical host/port matching;
- call existing GitHubWorkflowRunLoading exactly once.

Acceptance:
- no repository detail lookup;
- no connection-state mutation on history error.

## Task 4 — ActivityRuntimeModel history navigation state

Files:
- Modify: \`Sources/SchneeBarApp/ActivityRuntimeModel.swift\`
- Modify/add ActivityRuntimeModel tests.

RED:
- history opens while preserving selectedItem/detail;
- Back keeps same detail object/value and does not call detail loader;
- retry increments only history loader;
- dismissDetail clears history;
- cancellation prevents stale completion.

GREEN:
- add deliveryHistory state and loader/task lifecycle.

Acceptance:
- current detail navigation API remains source-compatible where practical.

## Task 5 — History UI and detail entry point

Files:
- Add: \`Sources/SchneeBarActivityFeature/DeliveryHistoryView.swift\`
- Modify: \`Sources/SchneeBarActivityFeature/ActivityDetailView.swift\`
- Modify: \`Sources/SchneeBarApp/PopoverRootView.swift\`
- Modify/add UI behavior tests.

RED:
- History action expected from loaded detail;
- Back action expected;
- loading/error/empty/list rendering helpers.

GREEN:
- preserve 340-point layout;
- use existing state icon language;
- history rows are browser links only in this slice.

Acceptance:
- failed history never hides/destroys the loaded detail.

## Task 6 — App wiring and one-request network regression

Files:
- Modify: \`Sources/SchneeBarApp/SchneeBarApp.swift\`
- Add/extend request-budget tests.

Implementation:
- retain GitHubWorkflowRunService as an AppDelegate property so the same authorized service can be used by provider and explicit history loader;
- configure ActivityRuntimeModel history loader;
- prove one history request:
  - /repos/{owner}/{repo}/actions/runs
  - status=completed
  - per_page=20
  - page=1
- prove zero history-time requests to pulls, commits, deployments, environments, jobs, or repository detail.

Acceptance:
- existing explicit Activity detail 12-request test remains exactly 12.

## Task 7 — Deterministic fixtures, visuals, roadmap

Files:
- Add/modify PreviewSupport history fixtures.
- Modify VisualHarness / VisualSnapshotCLI.
- Modify \`docs/DEVELOPMENT_PLAN.md\`.

Visual scenarios in Light/Dark:
- mixed default/non-default history;
- neutral/cancelled;
- empty;
- request failure.

Roadmap:
- mark standalone repository-scoped history/navigation implemented;
- keep persisted history, global picker, local row drill-down, richer evidence explanations deferred.

## Task 8 — Exact-head gate

- CI Build + Test success.
- Visual Regression success.
- CodeQL success.
- unresolved review threads = 0.
- requested-changes reviews = 0.
- PR mergeable.
- final diff confirms:
  - no new GitHub endpoint family;
  - no background polling;
  - no permission expansion;
  - one-request history budget;
  - existing 12-request detail budget unchanged.

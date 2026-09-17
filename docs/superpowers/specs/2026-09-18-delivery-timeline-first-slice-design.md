# Delivery Timeline First Slice Design

**Date:** 2026-09-18  
**Status:** Written design pending final review  
**Scope:** Phase 4 Delivery Timeline — first user-visible vertical slice

## Goal

Surface SchneeBar's existing GitHub workflow-correlation primitives in the workflow Activity detail screen so a user can understand a reliable delivery chain such as:

```text
Pull request workflow
        |
        v
Merged pull request
        |
        v
Base-branch workflow execution
```

The first slice must remain local-first, conservative, and demand-driven. Timeline data is loaded only when the user opens a Workflow activity detail. Normal Developer Activity polling must not gain new network requests.

## Current State

The repository already has the hard correlation primitives:

- `GitHubWorkflowExecutionCorrelator`;
- exact shared-PR correlation;
- high-confidence shared-head-SHA correlation;
- exact merged-PR correlation using explicit commit -> pull-request association;
- `GitHubPullRequestMetadataClient`;
- `GitHubCommitPullRequestClient`;
- workflow-run and workflow-job clients/services;
- Activity detail UI and deterministic Visual Regression infrastructure.

Those primitives are not yet wired into the production Activity-detail flow. Today, a Workflow activity detail loads only workflow jobs.

## Design Principles

1. **Evidence before presentation.** Branch names, timestamps, display titles, and workflow names must never create a delivery relationship by themselves.
2. **Demand-driven network use.** No correlation request is added to background polling.
3. **Partial failure isolation.** Timeline failure must not make successfully loaded workflow-job detail fail.
4. **Provider isolation.** GitHub DTOs stay inside GitHub/App adapter layers; Core and SwiftUI receive provider-neutral timeline models.
5. **Bounded work.** One detail-open action has explicit finite request limits.
6. **No false default-branch claim.** Until repository metadata proves the default branch, the UI describes the PR `baseRef` as the base branch rather than assuming it is the repository default branch.

## Non-goals

This slice does **not** add:

- a separate Delivery tab or global timeline browser;
- background timeline polling;
- SQLite persistence;
- deployment/environment events;
- recovery notifications;
- workflow re-run/cancel controls;
- superseded-run history;
- `run_attempt` history;
- inferred GitHub Actions `concurrency` groups;
- generic third-party delivery-provider/plugin contracts;
- new GitHub write permissions;
- repository default-branch discovery;
- speculative correlation from branch/time/name similarity.

## User Experience

A Workflow activity continues to open the existing detail screen. The detail screen gains a Delivery section above Jobs.

A correlated example is conceptually:

```text
Lamy210/SchneeBar
PR #47 · CI

Delivery
● PR #47 workflow
│  feature/... -> main
│
● Merged
│  into main
│
● Base branch · CI
   Succeeded

Correlation: Exact

Jobs
✓ Build
✓ Test
✓ CodeQL
```

When reliable relationship evidence does not exist:

```text
Delivery
Correlation evidence unavailable
```

When timeline-specific network work fails but Jobs loaded successfully:

```text
Delivery
Timeline temporarily unavailable

Jobs
...normal job detail remains usable...
```

The existing top-right Workflow destination remains unchanged.

## Core Contract

Add provider-neutral timeline primitives in `SchneeBarCore`.

```swift
public enum DeliveryTimelineConfidence: String, Codable, CaseIterable, Sendable {
    case exact
    case high
    case medium
    case unknown
}

public enum DeliveryTimelineEventKind: String, Codable, CaseIterable, Sendable {
    case pullRequest
    case merge
    case execution
}

public enum DeliveryTimelineStatus: String, Codable, CaseIterable, Sendable {
    case correlated
    case evidenceUnavailable
    case temporarilyUnavailable
}

public struct DeliveryTimelineEvent: Identifiable, Equatable, Sendable {
    public let id: String
    public let kind: DeliveryTimelineEventKind
    public let title: String
    public let detail: String?
    public let state: ActivityDetailState
    public let destinationURL: URL?
    public let occurredAt: Date?
}

public struct DeliveryTimelineSnapshot: Equatable, Sendable {
    public let status: DeliveryTimelineStatus
    public let confidence: DeliveryTimelineConfidence
    public let events: [DeliveryTimelineEvent]
}
```

`DeliveryTimelineSnapshot` invariants:

- `.correlated` requires at least two events and confidence other than `.unknown`;
- `.evidenceUnavailable` has no invented relationship and normally uses `.unknown`;
- `.temporarilyUnavailable` represents technical failure rather than absence of evidence;
- event order is delivery order, not severity order.

Extend `ActivityDetailSnapshot` with:

```swift
public let deliveryTimeline: DeliveryTimelineSnapshot?
```

The initializer defaults the new property to `nil` so existing non-Workflow and fixture call sites remain source-compatible where practical.

## GitHub Mapping

Add `GitHubDeliveryTimelineBuilder` in `SchneeBarGitHubActivityProvider`.

It is a pure mapper/correlator. It receives already-normalized GitHub models and returns a provider-neutral `DeliveryTimelineSnapshot`.

```swift
public struct GitHubDeliveryTimelineBuilder: Sendable {
    public init(
        correlator: GitHubWorkflowExecutionCorrelator = .init()
    )

    public func build(
        repositoryID: Int64,
        selectedRun: GitHubWorkflowRun,
        pullRequest: GitHubPullRequestMetadata?,
        baseRuns: [GitHubWorkflowRun],
        associatedPullRequestNumbersByRunID: [Int64: [Int]]
    ) -> DeliveryTimelineSnapshot
}
```

### Correlated path

For the first slice, the richest timeline requires:

1. the selected Workflow run references exactly one positive PR number;
2. matching PR metadata is available;
3. the PR is merged and has `mergedAt`;
4. a candidate run is on `pullRequest.baseRef`;
5. explicit commit -> PR association includes the same PR number;
6. `GitHubWorkflowExecutionCorrelator.correlateMergedPullRequest(...)` returns non-unknown evidence.

The builder emits:

1. Pull Request execution event;
2. Merge event;
3. correlated base-branch execution event.

The builder maps `GitHubWorkflowExecutionCorrelationConfidence` directly to the provider-neutral confidence enum.

### Partial correlation

If merged base-run evidence is unavailable but the selected run itself has reliable PR identity, the builder may show the Pull Request event alone only as context; it must return `.evidenceUnavailable`, not `.correlated`, because there is no delivery chain yet.

No branch/time/name heuristic may promote this state.

## GitHub Detail Loader

Add a demand-driven GitHub delivery timeline loader/service in `SchneeBarGitHub` or the App composition layer with one responsibility: obtain the normalized inputs needed by `GitHubDeliveryTimelineBuilder` under a strict request budget.

The preferred boundary is `GitHubDeliveryTimelineService` in `SchneeBarGitHub` because credential authorization and GitHub REST orchestration belong with the GitHub adapter, not SwiftUI.

```swift
public protocol GitHubDeliveryTimelineLoading: Sendable {
    func timelineEvidence(
        connection: GitHubConnection,
        identity: GitHubAccountIdentity,
        clientID: String?,
        repository: GitHubRepositoryAccess,
        runID: Int64
    ) async throws -> GitHubDeliveryTimelineEvidence
}
```

`GitHubDeliveryTimelineEvidence` remains provider-specific and contains only normalized GitHub models needed by the builder.

### Required exact-run lookup

The selected Activity item currently contains a trusted Workflow URL/run ID but not the full `GitHubWorkflowRun`. Add an exact single-run client/service path using GitHub's Workflow Run endpoint rather than depending on the run still being present in a recent-list window.

The single-run result must reuse the existing normalized `GitHubWorkflowRun` model and trusted destination reconstruction rules.

### Evidence loading sequence

For a selected Workflow run:

1. authorize the existing connection once;
2. load the selected run by exact run ID;
3. require exactly one positive PR number; otherwise stop with evidence unavailable;
4. load matching PR metadata;
5. if not merged, stop with evidence unavailable for this first slice;
6. list recent runs for `pullRequest.baseRef` with a fixed small limit;
7. prefer likely candidates for association lookup using non-authoritative ordering/filtering only;
8. load commit -> PR association for at most a fixed number of candidates;
9. let `GitHubWorkflowExecutionCorrelator` make the authoritative relationship decision.

Candidate ordering may use workflow ID, timestamps, or proximity only to reduce network work. Those fields must never become correlation evidence.

## Explicit Request Budget

Normal polling request budgets remain unchanged.

For one user-triggered timeline load, additional timeline work is bounded to:

- 1 exact selected-run request;
- 1 pull-request metadata request;
- 1 base-branch workflow-run list request;
- at most 4 commit -> pull-request association requests.

Maximum timeline-specific list/detail requests: **7** per explicit detail load, excluding existing Workflow Jobs pagination.

The base-run list uses a fixed limit of **20** for the first slice. Association lookup stops immediately after a valid non-unknown merged correlation is found.

No automatic retry loop is added. The user can use the existing detail Retry action.

## Candidate Selection

The service must keep candidate selection deterministic and false-positive resistant.

Before commit-association requests:

- candidate run ID must differ from the selected run ID;
- candidate branch must equal `pullRequest.baseRef` exactly after trimming;
- candidate head SHA must be non-empty;
- duplicate candidate head SHAs should be collapsed for association lookup to avoid redundant requests;
- candidate order is deterministic: same `workflowID` first, then `updatedAt` descending, then run ID descending.

`same workflowID` is only an optimization priority. A different-workflow candidate may still correlate when explicit commit -> PR association proves the relationship.

## Activity Detail Integration

`GitHubConnectionsRuntimeModel.loadActivityDetail(...)` remains the App-facing composition point.

The detail load performs two logically independent operations:

```text
Workflow detail open
      |
      +--> Workflow Jobs ------------> required for existing detail
      |
      +--> Delivery Timeline evidence -> best effort
```

Behavior:

- if Jobs fail, preserve the existing detail failure behavior;
- if Jobs succeed and timeline succeeds, return Jobs + timeline;
- if Jobs succeed and timeline has insufficient evidence, return Jobs + `.evidenceUnavailable`;
- if Jobs succeed and timeline throws, return Jobs + `.temporarilyUnavailable`;
- timeline failure must not replace the existing detail with `ActivityDetailLoadingError`.

Timeline work is cancelled with the existing Activity detail task when the user navigates back, selects another item, or retries.

## UI

`ActivityDetailView` renders Delivery before the Jobs list when `deliveryTimeline != nil`.

Presentation rules:

- section title: `Delivery`;
- correlated events render vertically in delivery order;
- each event uses an icon/state style consistent with existing Activity detail states;
- event destinations use `Link` only when a trusted URL exists;
- confidence copy is `Exact correlation`, `High-confidence correlation`, `Medium-confidence correlation`, or `Correlation unavailable`;
- `.evidenceUnavailable` is visually neutral and compact;
- `.temporarilyUnavailable` uses warning/secondary presentation but does not dominate the Jobs section;
- do not expose raw SHA unless a later product decision requires it;
- do not label `baseRef` as `default branch` without explicit repository evidence.

The view width remains 340 points for this slice unless Visual Regression proves the timeline unreadable. Prefer vertical content/scrolling over widening the popover by default.

## Trusted Destinations

All browser URLs remain reconstructed from the connection/repository identity or come from already-normalized trusted GitHub models.

Do not use provider response `html_url` values directly when current clients intentionally rebuild trusted URLs.

No token, private endpoint, request body, or raw provider error is placed in `DeliveryTimelineSnapshot`.

## Failure Semantics

### Evidence unavailable

Use when the available GitHub data cannot prove a chain, including:

- selected run has zero or multiple PR numbers;
- PR is not merged;
- merged timestamp is absent;
- no base-branch candidate is associated with the PR;
- candidate data is ambiguous;
- correlator returns `.unknown`.

This is not a connection-health failure.

### Temporarily unavailable

Use when timeline-specific work fails technically, including authorization, HTTP, decoding, or transport failure after the existing Activity context was otherwise valid.

This state does not make the GitHub connection unavailable and does not alter Activity polling caches.

## Caching

Do not add persistent or provider-wide timeline caching in this first slice.

The selected Activity detail owns the in-flight result through the existing `ActivityRuntimeModel` lifecycle. Closing or replacing the detail discards it.

This avoids stale delivery-chain state and keeps Phase 4 independent of the planned future ActivityStore/SQLite work.

## Concurrency and Cancellation

- use Swift structured concurrency;
- no new GCD/callback abstraction;
- cancellation propagates from the existing detail task;
- association lookups are sequential in deterministic candidate order so cancellation and the four-request cap remain simple and auditable;
- do not let stale completion from a dismissed detail update the selected detail, preserving current `ActivityRuntimeModel` identity checks.

## Testing Strategy

Development follows TDD.

### Core tests

Cover:

- correlated timeline invariants;
- evidence-unavailable snapshot;
- temporarily-unavailable snapshot;
- event ordering preservation;
- `ActivityDetailSnapshot` source compatibility/default `nil` timeline.

### GitHub builder tests

Cover:

- merged PR + associated base run -> exact three-event timeline;
- high-confidence mapping remains distinct from exact where applicable;
- wrong PR association -> evidence unavailable;
- wrong base branch -> evidence unavailable;
- unmerged PR -> evidence unavailable;
- missing/ambiguous PR identity -> evidence unavailable;
- different workflow ID can still correlate when explicit association proves it;
- deterministic candidate/result behavior.

### Service/client tests

Cover:

- exact Workflow Run endpoint decoding and trusted URL behavior;
- one authorization per timeline load;
- base branch query uses `branch = pullRequest.baseRef` and `limit = 20`;
- no association request when PR evidence is insufficient;
- association lookup stops on the first proven candidate;
- no more than four association requests;
- duplicate candidate SHAs do not cause duplicate association requests;
- cancellation stops remaining association requests.

### App/runtime tests

Cover:

- Jobs + correlated timeline;
- Jobs + evidence unavailable;
- Jobs + timeline technical failure still returns successful job detail;
- job failure preserves existing error behavior;
- stale/dismissed detail cannot repopulate the UI.

### Feature/Visual tests

Add deterministic fixtures for:

- exact PR -> merge -> base-branch execution timeline;
- evidence unavailable;
- timeline temporarily unavailable;
- correlated timeline with matrix-grouped Jobs below it;
- Light and Dark Visual Regression scenes.

## Expected Files

Expected Core changes:

- create `Sources/SchneeBarCore/DeliveryTimeline.swift`;
- modify `Sources/SchneeBarCore/ActivityDetail.swift`;
- add/extend Core tests.

Expected GitHub changes:

- extend `Sources/SchneeBarGitHub/GitHubActionsClient.swift` with exact run lookup;
- add an exact-run service/API surface if needed to preserve session-coordinator ownership;
- create `Sources/SchneeBarGitHub/GitHubDeliveryTimelineService.swift`;
- create provider-specific evidence model(s) near that service;
- reuse `GitHubPullRequestMetadataClient` and `GitHubCommitPullRequestClient` rather than duplicating endpoints.

Expected GitHub Activity provider changes:

- create `Sources/SchneeBarGitHubActivityProvider/GitHubDeliveryTimelineBuilder.swift`;
- add builder tests.

Expected App changes:

- modify `Sources/SchneeBarApp/GitHubConnectionsRuntimeModel+ActivityDetail.swift`;
- modify `Sources/SchneeBarApp/SchneeBarApp.swift` composition as required;
- extend App runtime tests.

Expected Feature/fixture changes:

- modify `Sources/SchneeBarActivityFeature/ActivityDetailView.swift`;
- add deterministic fixture support in `SchneeBarPreviewSupport`;
- extend Visual Harness / Snapshot CLI scenes;
- add Activity Feature behavior tests.

Expected documentation change after implementation:

- update `docs/DEVELOPMENT_PLAN.md` to mark the first user-visible Phase 4 timeline slice implemented without claiming deployments/default-branch discovery are complete.

## Acceptance Criteria

1. Opening a Workflow Activity detail may show a provider-neutral Delivery section above Jobs.
2. Normal background Developer Activity polling makes no new requests for Delivery Timeline.
3. A correlated PR -> merge -> base-branch execution chain is shown only when existing GitHub correlation logic has reliable evidence.
4. Branch, timestamp, workflow name, or display-title similarity alone never creates a relationship.
5. Timeline-specific network work is capped at seven explicit list/detail requests per detail load, with at most four commit-association requests.
6. Timeline failure never hides successfully loaded workflow Jobs.
7. Evidence absence is distinct from technical timeline failure.
8. The UI does not call the PR base branch the repository default branch without explicit evidence.
9. GitHub DTOs do not leak into Core or SwiftUI.
10. Existing job detail, matrix grouping, Activity polling budgets, supersession behavior, connection health, and cancellation semantics remain intact.
11. Deterministic Light/Dark Visual Regression covers correlated and unavailable timeline states.
12. Final implementation head must pass CI, Visual Regression, and CodeQL before merge.

## Self-review

- No placeholder requirements remain.
- The request budget is explicit and bounded.
- Correlation authority remains `GitHubWorkflowExecutionCorrelator`; candidate ordering is not evidence.
- Timeline technical failure is isolated from existing job detail.
- The design avoids claiming a default branch that the current repository model cannot prove.
- The first slice does not introduce persistent state or background polling.

## Deferred Follow-up

After this slice proves useful:

- repository default-branch metadata and explicit default-branch labeling;
- independent Delivery Timeline navigation/surface;
- deployments and environments;
- richer confidence/evidence explanations;
- recovery notifications;
- persisted delivery history;
- superseded/re-run attempt history;
- enterprise-specific real-world validation.

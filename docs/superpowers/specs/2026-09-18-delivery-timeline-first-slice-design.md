# Delivery Timeline First Slice Design

**Date:** 2026-09-18  
**Status:** Written design pending final review  
**Scope:** Phase 4 Delivery Timeline — first user-visible vertical slice

## Goal

Expose SchneeBar's existing GitHub workflow-correlation primitives in Workflow Activity detail so a user can inspect a reliable chain from a pull-request execution, through merge, to a proven execution on the pull request's base branch.

Timeline loading is demand-driven: it starts only when the user opens Workflow detail. Normal Developer Activity polling gains no new requests.

## Existing Foundation

Already implemented:

- `GitHubWorkflowExecutionCorrelator` with shared-PR, shared-head-SHA, and merged-PR correlation;
- exact merged-PR evidence using commit -> pull-request association;
- `GitHubPullRequestMetadataClient`;
- `GitHubCommitPullRequestClient`;
- workflow-run and workflow-job clients/services;
- Activity detail UI, matrix-job grouping, and deterministic Visual Regression.

Today production Activity detail loads workflow jobs only. The correlation primitives are not wired into that flow.

## Decisions

1. Delivery is shown inside the existing Workflow Activity detail, above Jobs.
2. Correlation is evidence-driven. Branch names, timestamps, workflow names, and display titles may order candidates but never prove a relationship.
3. `GitHubDeliveryTimelineService` lives in `SchneeBarGitHub` and owns authenticated GitHub REST orchestration.
4. `GitHubDeliveryTimelineBuilder` lives in `SchneeBarGitHubActivityProvider` and is a pure GitHub-model -> Core timeline mapper.
5. Core/SwiftUI receive provider-neutral timeline models only.
6. Timeline technical failure never hides successfully loaded Jobs.
7. No persistent timeline cache is added.
8. The UI calls `pullRequest.baseRef` the **base branch**, not the repository default branch, because the current repository model does not prove default-branch identity.

## Non-goals

This slice does not add:

- a separate Delivery tab/global history surface;
- background timeline polling;
- deployments/environments;
- recovery notifications;
- SQLite/persistent Activity history;
- workflow re-run/cancel actions;
- superseded/re-run-attempt history;
- repository default-branch discovery;
- generic third-party delivery provider/plugin contracts;
- speculative correlation from branch/time/name similarity.

## User Experience

Correlated state:

```text
Delivery
● PR #47 workflow
│  feature/... -> main
● Merged
│  into main
● Base branch · CI
   Succeeded

Exact correlation

Jobs
✓ Build
✓ Test
```

Insufficient evidence:

```text
Delivery
Correlation evidence unavailable
```

Timeline-specific technical failure with successful Jobs:

```text
Delivery
Timeline temporarily unavailable

Jobs
...normal job detail...
```

## Core Contract

Create `Sources/SchneeBarCore/DeliveryTimeline.swift`:

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

Invariants:

- `.correlated` has at least two events and non-`.unknown` confidence;
- `.evidenceUnavailable` does not invent a relationship and uses `.unknown` confidence;
- `.temporarilyUnavailable` represents technical failure, not missing evidence;
- event order is delivery order.

Extend `ActivityDetailSnapshot` with:

```swift
public let deliveryTimeline: DeliveryTimelineSnapshot?
```

The initializer defaults this property to `nil` to preserve existing call sites where practical.

## GitHub Evidence Model

Create `GitHubDeliveryTimelineEvidence` in `SchneeBarGitHub`:

```swift
public struct GitHubDeliveryTimelineEvidence: Equatable, Sendable {
    public let selectedRun: GitHubWorkflowRun
    public let pullRequest: GitHubPullRequestMetadata?
    public let baseRuns: [GitHubWorkflowRun]
    public let associatedPullRequestNumbersByRunID: [Int64: [Int]]
}
```

Missing reliable PR/merge evidence is represented by optional/empty normalized data, not an error. Transport/authentication/HTTP/decoding failures remain thrown errors.

## Exact Workflow Run Lookup

Extend `GitHubActionsClient` with an exact run lookup:

```swift
public func workflowRun(
    id: Int64,
    repository: GitHubRepositoryAccess,
    connection: GitHubConnection,
    credential: GitHubCredential
) async throws -> GitHubWorkflowRun
```

It uses GitHub's single Workflow Run endpoint and the same decoding, API-version, endpoint-resolution, and trusted web-URL rules as list loading.

Do **not** add this method to `GitHubWorkflowRunLoading` in this slice. `GitHubDeliveryTimelineService` authorizes once and then uses the clients directly, avoiding repeated credential acquisition and widespread test-stub churn.

## GitHubDeliveryTimelineService

Create `Sources/SchneeBarGitHub/GitHubDeliveryTimelineService.swift`.

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

The concrete service owns:

- `GitHubConnectionSessionCoordinator`;
- `GitHubActionsClient`;
- `GitHubPullRequestMetadataClient`;
- `GitHubCommitPullRequestClient`.

Loading sequence:

1. call `authorizedCredential(...)` exactly once;
2. load selected run by exact run ID;
3. normalize positive PR numbers; if there is not exactly one, return evidence with `pullRequest == nil` and no base runs/associations;
4. load that PR's metadata;
5. if the PR is not merged or lacks `mergedAt`, return selected-run + PR metadata with empty base evidence;
6. list Workflow runs using `GitHubWorkflowRunQuery(branch: pullRequest.baseRef, limit: 20)`;
7. deterministically order/filter candidates;
8. query commit -> PR associations for at most four unique candidate head SHAs;
9. stop association loading as soon as a candidate is proven to belong to the selected PR;
10. return normalized evidence to the builder.

## Explicit Request Budget

No background polling budget changes.

One explicit timeline load performs at most:

- 1 exact Workflow Run request;
- 1 PR metadata request;
- 1 base-branch Workflow Run list request;
- 4 commit -> PR association requests.

Maximum: **7 timeline-specific list/detail requests per Workflow detail load**, excluding the already-existing Workflow Jobs request/pagination.

No automatic retry loop is added. Existing detail Retry re-runs the user-triggered load.

## Candidate Selection

Before association requests:

- reject selected run ID itself;
- require candidate `headBranch`, trimmed, to equal `pullRequest.baseRef`, trimmed;
- require non-empty normalized candidate head SHA;
- collapse duplicate head SHAs so one commit is queried once;
- deterministic order: same `workflowID` first, then `updatedAt` descending, then run ID descending.

`workflowID`, timestamps, and ordering are optimization only. They never establish correlation.

A different-workflow candidate remains eligible if explicit commit -> PR association proves the selected PR relationship.

## GitHubDeliveryTimelineBuilder

Create `Sources/SchneeBarGitHubActivityProvider/GitHubDeliveryTimelineBuilder.swift`:

```swift
public struct GitHubDeliveryTimelineBuilder: Sendable {
    public init(
        correlator: GitHubWorkflowExecutionCorrelator = .init()
    )

    public func build(
        repositoryID: Int64,
        evidence: GitHubDeliveryTimelineEvidence
    ) -> DeliveryTimelineSnapshot
}
```

For a correlated three-event timeline, require:

1. selected run identifies exactly one positive PR number;
2. matching PR metadata is present;
3. PR is merged and has `mergedAt`;
4. candidate run is on `pullRequest.baseRef`;
5. candidate commit association includes the same PR number;
6. `correlateMergedPullRequest(...)` returns non-`.unknown` confidence.

Emit events in this order:

1. PR Workflow execution;
2. Merge;
3. Base-branch Workflow execution.

Map `GitHubWorkflowExecutionCorrelationConfidence` directly to Core confidence.

If no candidate is proven, return `.evidenceUnavailable`; do not promote based on branch/time/workflow-name similarity.

## Activity Detail Composition

`GitHubConnectionsRuntimeModel.loadActivityDetail(...)` remains the App composition point.

Its inputs become the existing `GitHubWorkflowJobService` plus `GitHubDeliveryTimelineLoading` and `GitHubDeliveryTimelineBuilder`.

Logical flow:

```text
Workflow detail open
      |
      +--> Workflow Jobs ---------------- required
      |
      +--> Delivery evidence -> builder -- best effort
```

Rules:

- Jobs failure preserves existing detail failure behavior;
- Jobs success + correlated timeline returns both;
- Jobs success + insufficient evidence returns Jobs + `.evidenceUnavailable`;
- Jobs success + timeline service error returns Jobs + `.temporarilyUnavailable`;
- timeline errors do not alter GitHub connection health or Activity polling caches;
- cancellation still originates from the existing Activity detail task, and stale selected-item identity checks remain authoritative.

`AppDelegate` creates one `GitHubDeliveryTimelineService` using the same session coordinator already used by GitHub services and injects it into the detail loader path.

## UI

`ActivityDetailView` renders Delivery before Jobs when `deliveryTimeline != nil`.

Presentation:

- section heading `Delivery`;
- events render vertically in supplied delivery order;
- use the existing `ActivityDetailState` visual language;
- trusted event URLs may render as `Link`;
- confidence copy: `Exact correlation`, `High-confidence correlation`, `Medium-confidence correlation`, or `Correlation unavailable`;
- `.evidenceUnavailable` stays visually neutral;
- `.temporarilyUnavailable` is a compact warning/secondary state;
- do not expose raw SHA;
- do not label `baseRef` as `default branch`.

Keep the current 340-point detail width initially; Visual Regression decides whether layout adjustments are necessary.

## Security and Privacy

- no token or credential enters Core/UI models;
- no raw provider error enters user-facing timeline models;
- URLs follow existing trusted reconstruction rules;
- no new write permission is requested;
- no private endpoint or repository data is committed in fixtures;
- no timeline request runs under `pull_request_target` or other privileged CI behavior.

## Caching and Performance

No persistent/provider-wide timeline cache is introduced. The selected Activity detail owns only the current in-memory result.

Association requests are sequential so the four-request cap, deterministic ordering, and cancellation behavior remain auditable. Use Swift structured concurrency; add no GCD/callback abstraction.

## Testing Strategy

Development is TDD.

### Core

- timeline status/confidence/event invariants;
- event order preservation;
- `ActivityDetailSnapshot` default `nil` timeline.

### GitHubActionsClient

- exact Workflow Run endpoint path;
- REST version header behavior;
- invalid run ID handling;
- normalized decoding;
- trusted workflow URL behavior.

### GitHubDeliveryTimelineService

- exactly one credential authorization;
- early return for zero/multiple PR numbers;
- early return for unmerged/malformed merge evidence;
- base query is `branch = baseRef`, `limit = 20`;
- candidate deterministic ordering;
- duplicate SHA de-duplication;
- stop at first proven association;
- max four association requests;
- cancellation stops remaining work.

### GitHubDeliveryTimelineBuilder

- merged PR + associated base run -> exact three-event timeline;
- non-exact confidence mapping remains distinct;
- wrong PR association -> evidence unavailable;
- wrong base branch -> evidence unavailable;
- missing/ambiguous PR identity -> evidence unavailable;
- different workflow ID still correlates when commit association proves it;
- no heuristic promotion.

### App Runtime

- Jobs + correlated timeline;
- Jobs + evidence unavailable;
- Jobs + timeline technical failure still succeeds as job detail;
- Jobs failure remains existing detail failure;
- stale/dismissed detail cannot repopulate current UI.

### Feature / Visual

Deterministic fixtures/scenes for:

- exact PR -> merge -> base-branch execution;
- evidence unavailable;
- temporarily unavailable;
- correlated timeline above matrix-grouped Jobs;
- Light and Dark appearances.

## Expected Files

Production:

- create `Sources/SchneeBarCore/DeliveryTimeline.swift`;
- modify `Sources/SchneeBarCore/ActivityDetail.swift`;
- modify `Sources/SchneeBarGitHub/GitHubActionsClient.swift`;
- create `Sources/SchneeBarGitHub/GitHubDeliveryTimelineService.swift`;
- create `Sources/SchneeBarGitHubActivityProvider/GitHubDeliveryTimelineBuilder.swift`;
- modify `Sources/SchneeBarApp/GitHubConnectionsRuntimeModel+ActivityDetail.swift`;
- modify `Sources/SchneeBarApp/SchneeBarApp.swift`;
- modify `Sources/SchneeBarActivityFeature/ActivityDetailView.swift`;
- extend `SchneeBarPreviewSupport`, Visual Harness, and Snapshot CLI fixtures/scenes;
- update `docs/DEVELOPMENT_PLAN.md` after implementation.

Tests are added/extended in the corresponding Core, GitHub, GitHubActivityProvider, App, and ActivityFeature test targets.

## Acceptance Criteria

1. Workflow detail can show Delivery above Jobs.
2. Background Activity polling makes zero new Delivery requests.
3. PR -> merge -> base-branch execution is displayed only with reliable existing correlator evidence.
4. Branch/time/workflow-name/display-title similarity alone never proves a link.
5. Timeline-specific requests are capped at seven per explicit detail load, including at most four association calls.
6. Timeline technical failure does not hide successfully loaded Jobs.
7. Insufficient evidence and technical failure are distinct states.
8. `baseRef` is not called the repository default branch without explicit evidence.
9. GitHub DTOs do not leak into Core or SwiftUI.
10. Existing job detail, matrix grouping, supersession, polling budgets, connection-health behavior, and cancellation semantics remain intact.
11. Correlated and unavailable states receive deterministic Light/Dark Visual Regression coverage.
12. Final implementation head passes CI, Visual Regression, and CodeQL before merge.

## Self-review

- No `TBD`, `TODO`, or optional implementation-boundary decision remains.
- `GitHubDeliveryTimelineService` ownership is fixed to `SchneeBarGitHub`.
- Exact-run lookup ownership is fixed to `GitHubActionsClient`; `GitHubWorkflowRunLoading` is intentionally unchanged.
- Request caps and candidate ordering are explicit.
- Correlation authority remains `GitHubWorkflowExecutionCorrelator`.
- Candidate ordering cannot become evidence.
- Timeline failure isolation and default-branch wording are explicit.
- Scope is one testable vertical slice; deployments/history/persistence remain deferred.

## Deferred Follow-up

- repository default-branch metadata;
- standalone Delivery Timeline navigation/history;
- deployments/environments;
- richer confidence/evidence explanations;
- recovery notifications;
- persisted delivery history;
- superseded/re-run-attempt history;
- enterprise-specific real-world validation.

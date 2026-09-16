# GitHub Review Requests + Checks Activity Design

**Date:** 2026-09-16  
**Status:** Approved design, amended after written-spec review  
**Scope:** Phase 3 Developer Activity

## Goal

Extend SchneeBar's Developer Activity from GitHub Actions-only activity into a small prioritized inbox that also surfaces:

- direct Pull Request review requests for the connected GitHub account;
- relevant Check Runs for commits justified by direct review requests or recently polled Workflow evidence;
- repository capability evidence for Actions, Review Requests, and Checks;
- deterministic priority semantics across the three activity sources.

The change must preserve SchneeBar's existing local-first architecture, bounded polling behavior, connection/session isolation, capability gating, and provider-neutral presentation boundary.

## Non-goals

This change does **not** add:

- team review-request membership resolution;
- arbitrary PR notifications, mentions, assignments, issue notifications, or a GitHub Inbox replacement;
- deployment/environment activity;
- write actions such as approving PRs, re-running checks, or dismissing reviews;
- a generic third-party plugin/source framework;
- persistent SQLite activity storage;
- Phase 4 delivery-timeline presentation;
- broad GHES compatibility expansion beyond the existing capability/endpoint policy.

Team review requests remain deferred because the current connection identity proves a user account, not team membership. SchneeBar must not infer team membership from repository access.

## Existing Architecture

SchneeBar currently has:

- provider-neutral `ActivityItem`, `ActivityState`, `ActivitySummary`, and detail snapshot primitives in `SchneeBarCore`;
- `GitHubActivityProvider` as the actor that owns repository polling, hot/cold scheduling, activity caches, connection generations, partial failure accounting, and Actions capability preflight;
- `GitHubWorkflowRunService` / `GitHubWorkflowJobService` behind the authenticated session coordinator;
- repository capability assessment for `.actions`, `.pullRequests`, `.checks`, and `.deployments`;
- repository-management presentation for Actions access;
- an Actions-specific local detail loader that resolves workflow jobs from a workflow-run destination URL.

The design keeps those boundaries. It does not move GitHub API DTOs into Core or SwiftUI.

## Design Decision

Use a **small provider-neutral inbox extension plus GitHub-specific review/check loaders**.

Do not append all behavior directly into the existing Actions loader, and do not build a generic plugin framework yet.

The resulting shape is:

```text
GitHubConnectionsRuntimeModel
        |
        v
GitHubActivityProvider
  |        |         |
  |        |         +-- Check Activity Source
  |        +------------ Review Request Activity Source
  +--------------------- Workflow Activity Source
        |
        v
[ActivityItem]
        |
        v
SchneeBarActivityFeature / Widget Engine
```

`GitHubActivityProvider` remains the scheduler/cache owner. Source-specific clients/services and mappers remain independently testable.

## Core Inbox Model

### Activity kind

Add:

```swift
public enum ActivityKind: String, Codable, CaseIterable, Sendable {
    case workflowRun
    case reviewRequest
    case checkRun
}
```

`ActivityKind` is presentation-neutral metadata used to choose interaction behavior and deterministic visual treatment. It must not contain GitHub identifiers.

### Attention

Add:

```swift
public enum ActivityAttention: String, Codable, CaseIterable, Sendable {
    case actionRequired
    case needsAttention
    case active
    case informational
}
```

Extend `ActivityItem` with:

```swift
public let kind: ActivityKind
public let attention: ActivityAttention
public let updatedAt: Date?
```

Existing fields remain unchanged.

### Backward-compatible decoding

`ActivityItem` is currently `Codable`; adding required synthesized fields would make older encoded values undecodable. Implement explicit decoding defaults:

- missing `kind` -> `.workflowRun`;
- missing `attention` -> derive from existing `state`:
  - `.failed` -> `.needsAttention`;
  - `.running`, `.waiting` -> `.active`;
  - `.success` -> `.informational`;
- missing `updatedAt` -> `nil`.

Existing initializers receive defaults that preserve current call sites where practical.

### Inbox ordering

Global ordering is deterministic:

1. `.actionRequired`
2. `.needsAttention`
3. `.active`
4. `.informational`

Within the same attention class, preserve meaningful state ordering before recency:

1. state rank: `.failed`, `.running`, `.waiting`, `.success`;
2. newer non-`nil` `updatedAt` first;
3. dated items before undated items;
4. repository name;
5. activity kind raw value;
6. stable activity ID.

The attention rank still gives direct review requests priority over CI failures, while the state rank preserves the existing running-before-waiting behavior for `.active` items.

### Source mapping

Workflow Runs:

- failed -> `needsAttention`;
- running / waiting -> `active`;
- successful -> `informational` when visible.

Direct Review Requests:

- state -> `.waiting`;
- attention -> `.actionRequired`.

Check Runs:

- `action_required`, `failure`, `timed_out` -> `.failed` + `.needsAttention`;
- queued/waiting/pending/requested -> `.waiting` + `.active`;
- in-progress -> `.running` + `.active`;
- success/neutral/skipped/cancelled/stale -> informational or ignored according to mapper policy; successful/ignored checks are not top-level inbox items by default.

## Activity Summary Semantics

`ActivitySummary` must stop assuming every item is CI.

Add attention counts, including at least:

```swift
public let actionRequired: Int
public let needsAttention: Int
```

The menu-bar label becomes activity-oriented rather than always prefixed with `CI`.

Priority for the compact label:

1. action required;
2. needs attention / failed;
3. running/active;
4. waiting;
5. clear state.

Exact strings remain a presentation choice, but deterministic fixtures must cover the new highest-priority review-request state and the no-activity state.

## Review Request Source

### API boundary

Create a dedicated GitHub read client and authenticated service, following the existing client/service split.

Suggested production types:

```swift
GitHubPullRequestListClient
GitHubReviewRequestService
GitHubReviewRequestActivityMapper
```

The client lists the most recently updated open Pull Requests for one repository and normalizes only fields SchneeBar needs:

```swift
public struct GitHubReviewRequest: Equatable, Sendable {
    let number: Int
    let title: String
    let headSHA: String
    let isDraft: Bool
    let updatedAt: Date
    let requestedReviewerIDs: Set<String>
    let webURL: URL
}
```

Periodic activity polling is intentionally bounded to **one page of 100 open PRs per selected repository poll**, ordered by most recently updated. It does not follow pagination links in this phase. This means a direct review request outside the 100 most recently updated open PRs of a repository is outside the Phase 3 polling window; a search-based/global GitHub inbox is explicitly out of scope.

Do not expose raw REST payloads outside the GitHub adapter.

### Identity matching

A direct review request exists only when `requestedReviewerIDs` contains the connected account's stable `GitHubAccountIdentity.id`.

Do not treat login text alone as proof when a stable reviewer ID is available. Do not infer team membership.

### URL trust

Ignore remote `html_url` for navigation. Rebuild the PR destination from the resolved trusted connection web endpoint plus repository owner/name and PR number, consistent with existing metadata clients.

### Review visibility

Only open PRs that directly request the connected account are emitted.

A successful subsequent poll that no longer returns the request removes the cached review activity.

Draft state does not independently hide an explicitly returned direct review request; the GitHub server is the source of truth for whether the user is currently requested.

## Check Run Source

### API boundary

Create:

```swift
GitHubCheckRunClient
GitHubCheckRunService
GitHubCheckRunActivityMapper
```

The client loads Check Runs for an explicit commit ref/SHA. It does **not** scan arbitrary repository history.

Normalize at least:

```swift
public enum GitHubCheckRunStatus: Equatable, Sendable {
    case queued
    case inProgress
    case completed
    case waiting
    case requested
    case pending
    case unknown(String)
}

public enum GitHubCheckRunConclusion: Equatable, Sendable {
    case actionRequired
    case cancelled
    case failure
    case neutral
    case success
    case skipped
    case stale
    case timedOut
    case unknown(String)
}

public struct GitHubCheckRun: Equatable, Sendable {
    let id: Int64
    let name: String
    let status: GitHubCheckRunStatus
    let conclusion: GitHubCheckRunConclusion?
    let appSlug: String?
    let headSHA: String
    let startedAt: Date?
    let completedAt: Date?
}
```

The Check Run enums intentionally remain separate from `GitHubWorkflowRunStatus` / `GitHubWorkflowRunConclusion`. In particular, `startup_failure` is a Workflow Run conclusion and is not modeled as a Check Run conclusion.

Each periodic Check request is intentionally bounded to **one page of 100 Check Runs for the candidate ref**. The client does not follow pagination links in this phase.

### Trusted navigation

Top-level check activity links to the trusted repository commit checks page reconstructed from the connection endpoint and `headSHA`. Do not navigate to arbitrary third-party `details_url` values from API payloads.

### Workflow evidence required for Check discovery

The existing `GitHubWorkflowRun` already contains `headSHA`, but the current `GitHubWorkflowActivity` does not. Check discovery must not depend only on top-level visible Workflow rows because successful Workflow Runs are normally filtered out of the inbox.

Retain normalized, provider-internal Workflow evidence for recently polled runs, conceptually:

```swift
struct GitHubWorkflowEvidence: Equatable, Sendable {
    let repositoryID: Int64
    let headSHA: String
    let classification: GitHubWorkflowActivityClassification
    let updatedAt: Date
    let isVisible: Bool
}
```

This evidence is GitHub-provider state, not a new Core/UI model. It may be represented by extending the existing normalized workflow activity type instead of introducing this exact type, but the implementation must preserve `headSHA` and whether an equivalent top-level Workflow row is visible.

### Candidate refs

Check requests are allowed only for refs already justified by recently observed activity evidence.

Per repository candidate priority:

1. direct review-request head SHAs, newest review first;
2. recently polled Workflow Run head SHAs, ordered by Workflow classification priority and recency, **whether or not that Workflow Run is visible as a top-level Activity item**.

Deduplicate SHAs before requesting Checks.

This explicitly covers the case where GitHub Actions succeeds and is hidden from the inbox while an external Check on the same commit fails.

Do not make an additional branch/default-branch discovery request solely to find Check Runs in this phase.

### GitHub Actions check duplication

GitHub Actions also creates Check Runs. Showing both a workflow failure and its individual GitHub Actions checks as independent top-level rows would create duplicate noise.

Policy:

- suppress a GitHub Actions-owned Check Run (`appSlug == "github-actions"`) only when the provider has current or cached **visible Workflow activity** for the same repository and head SHA;
- Workflow evidence that exists only for Check discovery, but does not produce a visible Workflow row, does **not** suppress a Check row;
- if no same-SHA visible Workflow activity exists, the Check Run remains eligible, including when Actions is unavailable, its poll failed, or the Workflow itself succeeded and was hidden;
- external/non-GitHub-Actions checks remain eligible.

This prevents duplicate workflow/check rows without hiding Checks as a fallback signal when the Actions surface cannot provide an equivalent visible row.

## Capability Gating

Reuse the existing `GitHubConnectionCapabilityAssessment`.

For each source:

- Workflow source uses `.actions`;
- Review source uses `.pullRequests`;
- Check source uses `.checks`.

`.unavailable` blocks the source without consuming a network request.

`.available` and `.unknown` remain requestable, matching the existing conservative capability policy.

A definitive capability block is reported separately from attempted network work.

### Connection health is separate from source capability

Repository capability state does not define whether the GitHub connection itself is healthy.

If Actions, Reviews, and Checks are all definitively unavailable because permissions are missing, but the authenticated session and repository inventory are valid, the connection remains `.connected`. The management UI exposes the unavailable surfaces instead of marking the whole connection unavailable.

Connection-level `.unavailable` remains reserved for session/inventory/endpoint conditions that prevent the connection from operating, or for attempted source failures whose aggregate runtime policy genuinely represents an operational outage. A capability block by itself never transitions a healthy connection to `.unavailable`.

Authentication failure remains connection-wide and transitions to `.authenticationRequired`.

## Polling and Request Budget

SchneeBar is a menu-bar utility and must remain mostly asleep. Adding two sources must not multiply requests without a hard bound.

Default **per-connection, per-refresh** source budgets:

- Workflow repository polls: existing maximum of 8;
- Review repository polls: maximum of 4, one HTTP page/request each;
- Check ref polls: maximum of 4 total, maximum of 2 refs per repository, one HTTP page/request each.

The periodic top-level source budget is therefore a hard maximum of **16 HTTP list requests per connection per refresh**: 8 Workflow + 4 Review + 4 Check. No Review or Check pagination occurs inside that periodic refresh.

This budget applies to activity source list requests. Session-layer token refresh or other connection-management traffic is outside this source-list budget.

The provider maintains separate source poll state so one hot Actions repository does not permanently starve review scanning.

Review polling reserves at least one cold repository slot when eligible repositories exceed its budget.

Check polling is demand-driven from current/cached review/workflow evidence and has no independent cold-repository scan.

## Provider State

Retain one connection-level generation counter for stale async-work rejection.

Add source-specific caches/poll state under the connection:

```text
Workflow cache/evidence key: connection + repository
Review cache            key: connection + repository
Check cache             key: connection + repository + head SHA
```

`reset(connectionID:)` invalidates the generation and clears all three source caches, Workflow evidence, and poll state.

A repository leaving monitoring scope removes all source caches/evidence for that repository.

### Formal source result model

Make source-level accounting an explicit provider contract rather than a conceptual implementation detail:

```swift
public enum GitHubActivitySurface: String, CaseIterable, Hashable, Sendable {
    case workflows
    case reviewRequests
    case checks
}

public struct GitHubActivityTargetFailure: Equatable, Sendable {
    public let surface: GitHubActivitySurface
    public let repositoryID: Int64
    public let repositoryFullName: String
    public let reason: GitHubRepositoryActivityFailureReason
}

public struct GitHubActivitySurfaceResult: Equatable, Sendable {
    public let surface: GitHubActivitySurface
    public let items: [ActivityItem]
    public let failures: [GitHubActivityTargetFailure]
    public let successfulTargetCount: Int
    public let attemptedTargetCount: Int
    public let blockedTargetCount: Int
}
```

A Check target is a repository/ref pair, so multiple Check targets may share the same `repositoryID`; tests and internal scheduling may retain the ref separately where needed. The public failure model does not expose commit SHAs unless a concrete UI/debug requirement appears.

The aggregate `GitHubActivityLoadResult` contains source results, or an equivalent keyed representation, and may expose compatibility aggregate counts if existing runtime call sites need a migration path. It must preserve source identity; failures cannot be flattened into repository-only evidence.

### Partial failures

One source failing must not erase successful items from another source.

The runtime must be able to distinguish:

- no request because capability is unavailable;
- attempted request failed;
- another source for the same repository succeeded.

Authentication failure from any attempted source escalates the connection to `.authenticationRequired`, resets provider state for that connection, and follows the existing recovery path.

Transient network failure preserves existing last-known-good cache behavior. A later successful source poll replaces its own cache with current server evidence, including an empty result when an activity has been resolved.

A capability-only block does not make the connection unavailable. For non-auth attempted failures, runtime connection status is derived from attempted operational outcomes, not from `blockedTargetCount` alone.

## Repository Management Capability UI

Replace the Actions-only access presentation with a small three-surface access model.

Suggested presentation model:

```swift
public struct GitHubRepositoryActivityAccessModel: Equatable, Sendable {
    let actions: GitHubRepositoryActivityAccessPresentation
    let reviewRequests: GitHubRepositoryActivityAccessPresentation
    let checks: GitHubRepositoryActivityAccessPresentation
}
```

`GitHubRepositoryOptionModel` owns this model instead of a single `actionsAccess` field.

Presentation rules:

- available surfaces stay visually quiet;
- unverified and unavailable surfaces produce compact badges/summary labels;
- badges must name the surface (`Actions`, `Reviews`, `Checks`);
- monitoring selection remains repository-based, not source-based in this phase.

Do not add per-source enable/disable preferences yet.

## Activity Interaction UI

The current chevron/local detail behavior is Workflow Run-specific.

Rules:

- `.workflowRun` may show the local inspect chevron and use the existing workflow-job detail loader;
- `.reviewRequest` is a browser destination only;
- `.checkRun` is a browser destination only in this phase.

`ActivityPopoverView` must not offer an inspect button for activity kinds that have no local detail loader.

Accessibility/help text must stop saying `workflow` for non-workflow rows.

## Composition Root

`AppDelegate` continues to construct services explicitly.

Expected additions:

```text
GitHubPullRequestListClient / ReviewRequestService
GitHubCheckRunClient / CheckRunService
       |
       +--> GitHubActivityProvider
```

The session coordinator remains the only credential/session authority. New services load authorized credentials through the same established pattern as Workflow services; tokens never enter App/UI state.

## Security and Privacy Invariants

- never log or expose access/refresh tokens;
- never persist API DTOs containing unnecessary private repository metadata;
- browser URLs are reconstructed from trusted connection endpoints where possible;
- direct review identity matching uses stable GitHub account IDs;
- team membership is not inferred;
- capability-unavailable sources make zero API requests;
- one connection/account cannot populate another connection's cache;
- repository monitoring selection gates all three sources;
- stale work after reset/disable/repository-selection changes cannot repopulate caches.

## Testing Strategy

Implementation follows RED -> GREEN -> refactor.

### Core tests

Cover:

- backward-compatible `ActivityItem` decoding;
- attention ordering;
- state ordering within an attention class (`running` before `waiting`);
- timestamp and stable-ID tie breakers;
- new `ActivitySummary` semantics.

### Review client/service tests

Cover:

- direct reviewer ID match;
- another reviewer only -> no activity;
- multiple requested reviewers including current account;
- renamed login does not break stable-ID match;
- periodic request uses one page / maximum 100 PRs;
- private repository permission errors;
- 401 / 403 / 404 / network mapping;
- trusted PR URL reconstruction;
- successful empty refresh removes cached review activity;
- team-only request is not emitted.

### Check client/service/mapper tests

Cover:

- exact Check Run status/conclusion normalization, including unknown-value preservation;
- `startup_failure` is not modeled as a known Check Run conclusion;
- queued/in-progress/failure/action-required/success activity mapping;
- periodic request uses one page / maximum 100 Check Runs;
- trusted commit-check URL reconstruction;
- candidate SHA de-duplication;
- review SHA precedence over workflow SHA;
- successful hidden Workflow evidence still contributes a candidate SHA;
- external Check failure is discovered when the same-SHA Workflow succeeded and is hidden;
- maximum two refs per repository;
- maximum four check requests per refresh;
- same-SHA GitHub Actions Check suppression when visible Workflow evidence exists;
- GitHub Actions Check fallback when same-SHA visible Workflow evidence does not exist;
- successful/neutral/skipped checks omitted from top-level inbox by default.

### Provider tests

Cover:

- `.pullRequests` unavailable -> no review network call;
- `.checks` unavailable -> no check network call;
- unknown capability remains requestable;
- formal surface result preserves source identity;
- partial surface success/failure accounting;
- all three surfaces capability-blocked while session/inventory is healthy -> connection remains connected;
- capability block alone never produces connection-level `.unavailable`;
- 401 from any attempted source -> authentication-required failure;
- multi-account and multi-connection cache isolation;
- monitoring-selection pruning;
- generation/reset rejection of stale cross-source completions;
- hard maximum of 16 periodic source list requests per connection/refresh;
- cold review repositories are not starved by hot Actions repositories.

### App/runtime tests

Cover:

- aggregate ordering across review/check/workflow items;
- running Workflow activity sorts before waiting Workflow activity within `.active`;
- connection status remains connected on partial non-auth failures when another attempted source succeeds;
- capability-only blocks do not downgrade a healthy connection;
- authentication failure triggers existing reauthentication state;
- repository-management presentation maps all three capability surfaces.

### Visual regression

Add deterministic fictional scenes for:

1. mixed inbox: direct review request + failed external check + running workflow;
2. review-request-only inbox;
3. Checks unavailable / Reviews unverified capability management while the connection remains connected;
4. multiple repositories with deterministic priority ordering.

Fixtures must contain no real repository, account, enterprise URL, token, or private data.

## Expected File Boundaries

Likely additions/modifications:

```text
Sources/SchneeBarCore/ActivityItem.swift
Sources/SchneeBarCore/ActivitySummary.swift
Sources/SchneeBarGitHub/GitHubPullRequestListClient.swift
Sources/SchneeBarGitHub/GitHubReviewRequestService.swift
Sources/SchneeBarGitHub/GitHubCheckRunClient.swift
Sources/SchneeBarGitHub/GitHubCheckRunService.swift
Sources/SchneeBarGitHubActivityProvider/GitHubActivityProvider.swift
Sources/SchneeBarGitHubActivityProvider/GitHubActivitySurfaceResult.swift
Sources/SchneeBarGitHubActivityProvider/GitHubReviewRequestActivityMapper.swift
Sources/SchneeBarGitHubActivityProvider/GitHubCheckRunActivityMapper.swift
Sources/SchneeBarGitHubFeature/GitHubConnectionManagementView.swift
Sources/SchneeBarActivityFeature/ActivityPopoverView.swift
Sources/SchneeBarApp/GitHubConnectionsRuntimeModel.swift
Sources/SchneeBarApp/SchneeBarApp.swift
Sources/SchneeBarPreviewSupport/*
Sources/SchneeBarVisualHarness/*
Sources/SchneeBarVisualSnapshotCLI/*
Tests/SchneeBarCoreTests/*
Tests/SchneeBarGitHubTests/*
Tests/SchneeBarGitHubActivityProviderTests/*
Tests/SchneeBarAppTests/*
docs/DEVELOPMENT_PLAN.md
```

Exact file splits may be refined in the implementation plan, but module ownership must remain as specified here. Workflow evidence may live in the provider file or a focused internal file; it must not leak into Core solely to support GitHub Check discovery.

## Delivery Sequence

1. Core activity kind/attention/summary semantics.
2. Review Request client/service/mapper.
3. Check Run client/service/mapper and Workflow-evidence candidate/dedup policy.
4. Formal multi-source result model plus provider scheduling, caching, capability gating, and failure accounting.
5. Runtime/composition wiring, including separation of connection health from capability-only blocks.
6. Repository capability presentation.
7. Activity interaction/UI updates.
8. deterministic fixtures + visual regression.
9. update `docs/DEVELOPMENT_PLAN.md` after verification.
10. CI + Visual Regression + CodeQL on the exact ready-for-review head before merge.

## Acceptance Criteria

The feature is complete when all of the following are true:

- a PR directly requesting the connected account appears above CI activity when it is inside the bounded recent-PR polling window;
- team-only review requests are not guessed or shown;
- relevant external Check Runs appear only for bounded, activity-derived commit refs;
- a successful hidden Workflow Run can still seed Check discovery for its head SHA;
- an external Check failure is visible even when the same-SHA GitHub Actions Workflow succeeded and was hidden;
- GitHub Actions checks do not duplicate same-SHA visible Workflow activity;
- GitHub Actions checks remain usable as fallback when no equivalent visible Workflow evidence exists;
- Review and Check capability blocks perform zero source requests;
- capability-only blocks do not mark an otherwise healthy GitHub connection unavailable;
- a failure in one source does not erase successful activity from another source;
- a 401 from any attempted source enters the existing authentication-required recovery state;
- repository monitoring scope applies consistently to Actions, Reviews, and Checks;
- one periodic refresh performs at most 16 top-level activity source list requests per connection;
- multi-account/connection caches remain isolated;
- non-workflow activity never shows the workflow-job inspect affordance;
- capability management visibly distinguishes unavailable/unverified Actions, Reviews, and Checks;
- deterministic unit/runtime/visual tests pass;
- CI, Visual Regression, and CodeQL are green on the exact final PR head.
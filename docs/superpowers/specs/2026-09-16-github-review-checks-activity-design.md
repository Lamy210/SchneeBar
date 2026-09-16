# GitHub Review Requests + Checks Activity Design

**Date:** 2026-09-16  
**Status:** Approved design, awaiting written-spec review  
**Scope:** Phase 3 Developer Activity

## Goal

Extend SchneeBar's Developer Activity from GitHub Actions-only activity into a small prioritized inbox that also surfaces:

- direct Pull Request review requests for the connected GitHub account;
- relevant Check Runs for commits already represented by visible review/workflow context;
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

Within the same attention class:

1. newer non-`nil` `updatedAt` first;
2. dated items before undated items;
3. repository name;
4. activity kind raw value;
5. stable activity ID.

This gives direct review requests priority over CI failures while still preserving deterministic ordering.

### Source mapping

Workflow Runs:

- failed -> `needsAttention`;
- running / waiting -> `active`;
- successful -> `informational` when visible.

Direct Review Requests:

- state -> `.waiting`;
- attention -> `.actionRequired`.

Check Runs:

- `action_required`, `failure`, `timed_out`, `startup_failure` -> `.failed` + `.needsAttention`;
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

Exact strings are presentation details, but deterministic fixtures must cover the new highest-priority review-request state.

## Review Request Source

### API boundary

Create a dedicated GitHub read client and authenticated service, following the existing client/service split.

Suggested production types:

```swift
GitHubPullRequestListClient
GitHubReviewRequestService
GitHubReviewRequestActivityMapper
```

The client lists open Pull Requests for one repository with bounded pagination and normalizes only fields SchneeBar needs:

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

### Trusted navigation

Top-level check activity links to the trusted repository commit checks page reconstructed from the connection endpoint and `headSHA`. Do not navigate to arbitrary third-party `details_url` values from API payloads.

### Candidate refs

Check requests are allowed only for refs already justified by user-visible activity context.

Per repository candidate priority:

1. direct review-request head SHAs, newest review first;
2. visible workflow-run head SHAs, ordered by workflow activity priority and recency.

Deduplicate SHAs before requesting Checks.

Do not make an additional branch/default-branch discovery request solely to find Check Runs in this phase.

### GitHub Actions check duplication

GitHub Actions also creates Check Runs. Showing both a workflow failure and its individual GitHub Actions checks as independent top-level rows would create duplicate noise.

Policy:

- when Actions is requestable for the repository, suppress top-level Check Runs whose normalized `appSlug` is `github-actions`;
- when Actions is definitively unavailable but Checks is requestable, GitHub Actions-owned Check Runs may be shown as a fallback signal;
- external/non-GitHub-Actions checks remain eligible.

This policy is source-level and must be unit tested.

## Capability Gating

Reuse the existing `GitHubConnectionCapabilityAssessment`.

For each source:

- Workflow source uses `.actions`;
- Review source uses `.pullRequests`;
- Check source uses `.checks`.

`.unavailable` blocks the source without consuming a network request.

`.available` and `.unknown` remain requestable, matching the existing conservative capability policy.

A definitive capability block is reported separately from attempted network work.

## Polling and Request Budget

SchneeBar is a menu-bar utility and must remain mostly asleep. Adding two sources must not multiply requests without a hard bound.

Default **per-connection, per-refresh** source budgets:

- Workflow repository polls: existing maximum of 8;
- Review repository polls: maximum of 4;
- Check ref polls: maximum of 4 total, maximum of 2 refs per repository.

Worst-case source request count is therefore bounded to 16 primary list requests per connection per refresh before pagination. Pagination itself remains bounded by each client and must have an explicit maximum page limit.

The provider maintains separate source poll state so one hot Actions repository does not permanently starve review scanning.

Review polling reserves at least one cold repository slot when eligible repositories exceed its budget.

Check polling is demand-driven from current/cached review/workflow context and has no independent cold-repository scan.

## Provider State

Retain one connection-level generation counter for stale async-work rejection.

Add source-specific caches/poll state under the connection:

```text
Workflow cache       key: connection + repository
Review cache         key: connection + repository
Check cache          key: connection + repository + head SHA
```

`reset(connectionID:)` invalidates the generation and clears all three source caches and poll state.

A repository leaving monitoring scope removes all source caches for that repository.

### Partial failures

One source failing must not erase successful items from another source.

Track source-level accounting, conceptually:

```swift
GitHubActivitySurfaceResult
- surface
- items
- failures
- successfulTargetCount
- attemptedTargetCount
- blockedTargetCount
```

The public aggregate load result may remain one type, but it must preserve enough surface information for runtime status and tests to distinguish:

- no request because capability is unavailable;
- attempted request failed;
- another source for the same repository succeeded.

Authentication failure from any attempted source escalates the connection to `.authenticationRequired`, resets provider state for that connection, and follows the existing recovery path.

Transient network failure preserves existing last-known-good cache behavior. A later successful source poll replaces its own cache with current server evidence, including an empty result when an activity has been resolved.

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
- timestamp and stable-ID tie breakers;
- new `ActivitySummary` semantics.

### Review client/service tests

Cover:

- direct reviewer ID match;
- another reviewer only -> no activity;
- multiple requested reviewers including current account;
- renamed login does not break stable-ID match;
- pagination and page bound;
- private repository permission errors;
- 401 / 403 / 404 / network mapping;
- trusted PR URL reconstruction;
- successful empty refresh removes cached review activity;
- team-only request is not emitted.

### Check client/service/mapper tests

Cover:

- queued/in-progress/failure/action-required/success normalization;
- trusted commit-check URL reconstruction;
- candidate SHA de-duplication;
- review SHA precedence over workflow SHA;
- maximum two refs per repository;
- maximum four check requests per refresh;
- GitHub Actions-owned check suppression when Actions is requestable;
- GitHub Actions-owned check fallback when Actions is definitively unavailable;
- successful/neutral/skipped checks omitted from top-level inbox by default.

### Provider tests

Cover:

- `.pullRequests` unavailable -> no review network call;
- `.checks` unavailable -> no check network call;
- unknown capability remains requestable;
- partial surface success/failure accounting;
- 401 from any attempted source -> authentication-required failure;
- multi-account and multi-connection cache isolation;
- monitoring-selection pruning;
- generation/reset rejection of stale cross-source completions;
- bounded combined request count;
- cold review repositories are not starved by hot Actions repositories.

### App/runtime tests

Cover:

- aggregate ordering across review/check/workflow items;
- connection status remains connected on partial non-auth failures;
- authentication failure triggers existing reauthentication state;
- repository-management presentation maps all three capability surfaces.

### Visual regression

Add deterministic fictional scenes for:

1. mixed inbox: direct review request + failed external check + running workflow;
2. review-request-only inbox;
3. Checks unavailable / Reviews unverified capability management;
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

Exact file splits may be refined in the implementation plan, but module ownership must remain as specified here.

## Delivery Sequence

1. Core activity kind/attention/summary semantics.
2. Review Request client/service/mapper.
3. Check Run client/service/mapper and candidate/dedup policy.
4. Multi-source provider scheduling, caching, capability gating, and failure accounting.
5. Runtime/composition wiring.
6. Repository capability presentation.
7. Activity interaction/UI updates.
8. deterministic fixtures + visual regression.
9. update `docs/DEVELOPMENT_PLAN.md` after verification.
10. CI + Visual Regression + CodeQL on the exact ready-for-review head before merge.

## Acceptance Criteria

The feature is complete when all of the following are true:

- a PR directly requesting the connected account appears above CI activity;
- team-only review requests are not guessed or shown;
- relevant external Check Runs appear only for bounded, activity-derived commit refs;
- GitHub Actions checks do not duplicate normal Actions activity when Actions is requestable;
- Review and Check capability blocks perform zero source requests;
- a failure in one source does not erase successful activity from another source;
- a 401 from any attempted source enters the existing authentication-required recovery state;
- repository monitoring scope applies consistently to Actions, Reviews, and Checks;
- one refresh has a hard bounded request budget;
- multi-account/connection caches remain isolated;
- non-workflow activity never shows the workflow-job inspect affordance;
- capability management visibly distinguishes unavailable/unverified Actions, Reviews, and Checks;
- deterministic unit/runtime/visual tests pass;
- CI, Visual Regression, and CodeQL are green on the exact final PR head.

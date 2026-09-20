# GitHub Default-Branch Discovery — Phase 4 Fourth Vertical Slice Design

Date: 2026-09-20  
Status: Proposed — awaiting written-spec review  
Base: current `main` after PR #51, PR #52, and PR #53 integration

## Context

Phase 4 currently has an evidence-backed explicit Workflow-detail path:

`Pull Request workflow → merge → correlated base-branch execution → exact-SHA deployment → optional Environment protection metadata`

Phase 4 now includes the merged Deployment and Environment enrichment slices from PR #51, PR #52, and PR #53 while keeping the full explicit-detail feature-network ceiling at twelve HTTP requests.

The first Delivery Timeline slice intentionally labels a correlated execution as **Base branch** rather than **Default branch** because the repository model does not currently prove the repository's default branch. The GitHub repository payload already exposes `default_branch`, but `GitHubAccessClient.RepositoryPayload` discards it.

The current App detail path also reconstructs `GitHubRepositoryAccess` from `GitHubRepositoryOptionModel`. That reconstruction preserves repository identity and basic access but would discard any provider metadata added only to `GitHubRepositoryAccess`, including the default branch.

GitHub REST repository responses include `default_branch`; SchneeBar already downloads repository inventory during connection/session management. Therefore this slice can establish default-branch identity without adding any new feature HTTP request.

Relevant GitHub documentation:

- GitHub repository response examples include `default_branch`: https://docs.github.com/en/rest/apps/installations
- REST API version currently used by SchneeBar GitHub.com/GHE.com access inventory: `2026-03-10`

## Goals

1. Preserve the repository's explicit GitHub `default_branch` value from existing access-inventory responses.
2. Add zero new HTTP requests.
3. Keep the complete explicit-detail Delivery ceiling at twelve feature HTTP requests.
4. Allow Delivery Timeline presentation to say **Default branch** only when repository metadata proves that the Pull Request base branch exactly equals the repository default branch.
5. Preserve **Base branch** wording when default-branch identity is absent, empty, ambiguous, or different.
6. Keep default-branch metadata descriptive only; it must not establish or weaken Delivery correlation.
7. Keep non-default-target Pull Request timelines fully supported.
8. Stop reconstructing detail-path repository access from the repository-management UI model; use the authoritative runtime access inventory instead.
9. Preserve backward compatibility for existing `GitHubRepositoryAccess` and `GitHubDeliveryTimelineEvidence` construction in tests and call sites.
10. Add deterministic Light/Dark visual coverage for proven-default and non-default base branch timelines.

## Non-goals

This slice does not implement:

- a new `GET /repos/{owner}/{repo}` request;
- periodic/default-branch polling;
- branch inventory;
- branch protection discovery;
- rulesets;
- default-branch editing;
- default-branch migration;
- default-branch inference from workflow activity;
- case-insensitive branch matching;
- standalone Delivery history/navigation;
- recovery notifications;
- persisted Delivery history;
- repository administration;
- GitHub branch write actions.

## Chosen Approach

Use the `default_branch` value already present in repository inventory.

Logical data flow:

```text
GitHub access inventory response
        |
        | repository.default_branch
        v
GitHubAccessClient.RepositoryPayload
        |
        | normalize missing/null/blank -> nil
        v
GitHubRepositoryAccess.defaultBranch
        |
        +--> Activity/background providers (metadata carried, behavior unchanged)
        |
        +--> GitHubConnectionsRuntimeModel inventory
                  |
                  | explicit Workflow detail resolves repository
                  | directly from runtime inventory
                  v
        GitHubDeliveryTimelineService
                  |
                  v
        GitHubDeliveryTimelineEvidence.repositoryDefaultBranch
                  |
                  v
        GitHubDeliveryTimelineBuilder
                  |
                  +--> PR baseRef exactly equals proven default branch
                  |       -> "Default branch · CI"
                  |
                  +--> otherwise
                          -> "Base branch · CI"
```

No extra network request is introduced.

## Why This Approach

### Selected: preserve default branch from existing inventory

Advantages:

- zero additional HTTP requests;
- metadata arrives through an endpoint SchneeBar already needs;
- works naturally with repository selection/capability inventory;
- no duplicate repository lookup on each detail open;
- exact repository metadata, not a workflow heuristic;
- keeps the twelve-request explicit-detail ceiling unchanged.

### Rejected: `GET /repos/{owner}/{repo}` on detail open

This would independently prove the default branch but adds one request every time an eligible detail opens, raising the feature ceiling from twelve to thirteen without adding information that the session inventory already carries.

### Rejected: treat Pull Request `baseRef` as the default branch

A Pull Request can target a release or maintenance branch. `baseRef` proves the merge target, not repository default-branch identity. This would create false **Default branch** claims.

## Repository Access Model

Extend `GitHubRepositoryAccess`:

```swift
public struct GitHubRepositoryAccess: Equatable, Sendable, Identifiable {
    public let id: Int64
    public let name: String
    public let fullName: String
    public let isPrivate: Bool
    public let webURL: URL
    public let ownerLogin: String
    public let permissions: GitHubRepositoryPermissions
    public let defaultBranch: String?

    public init(
        id: Int64,
        name: String,
        fullName: String,
        isPrivate: Bool,
        webURL: URL,
        ownerLogin: String,
        permissions: GitHubRepositoryPermissions,
        defaultBranch: String? = nil
    )
}
```

The default argument keeps existing call sites source-compatible.

Rules:

- trim leading/trailing whitespace/newlines;
- missing key -> `nil`;
- explicit `null` -> `nil`;
- empty/whitespace-only string -> `nil`;
- any other non-empty string is retained exactly after trimming;
- do not lowercase or case-fold;
- do not validate against observed workflow branches;
- do not reject the repository because default-branch metadata is absent.

## Access Client DTO Normalization

Extend the private repository DTO:

```swift
private struct RepositoryPayload: Decodable {
    let id: Int64
    let name: String
    let fullName: String
    let isPrivate: Bool
    let owner: AccountPayload
    let permissions: RepositoryPermissionPayload?
    let defaultBranch: String?

    private enum CodingKeys: String, CodingKey {
        case id
        case name
        case fullName = "full_name"
        case isPrivate = "private"
        case owner
        case permissions
        case defaultBranch = "default_branch"
    }
}
```

Mapping:

```swift
defaultBranch: normalizedOptionalBranch(payload.defaultBranch)
```

The absence of `default_branch` must not convert the repository payload into `.invalidResponse`.

## Runtime Repository Authority

The explicit Activity-detail path currently derives repository access through:

```text
managementModel(profileID:)
  -> GitHubRepositoryOptionModel
  -> makeRepository(option:webBaseURL:)
  -> reconstructed GitHubRepositoryAccess
```

That path is lossy because the management model is presentation data.

Replace it with an inventory-backed helper in `GitHubConnectionsRuntimeModel`:

```swift
func repositoryAccess(
    profileID: UUID,
    fullName: String
) -> GitHubRepositoryAccess? {
    guard let inventory = inventoryByConnectionID[profileID] else {
        return nil
    }

    let matches = accessibleRepositories(inventory).filter {
        $0.fullName == fullName
    }
    guard matches.count == 1 else {
        return nil
    }
    return matches[0]
}
```

The exact implementation may avoid allocating an intermediate array, but behavior is fixed:

- resolve only from the active profile's current access inventory;
- require exact `fullName` equality;
- more than one matching repository is treated as ambiguous and unavailable;
- do not reconstruct permissions or provider metadata from UI models.

`GitHubRepositoryOptionModel` does **not** gain a default-branch field in this slice because repository management UI does not need to display it.

This is a targeted boundary correction: provider repository metadata remains in the provider/runtime model rather than being round-tripped through a SwiftUI presentation model.

## Delivery Evidence

Extend `GitHubDeliveryTimelineEvidence`:

```swift
public struct GitHubDeliveryTimelineEvidence: Equatable, Sendable {
    public let selectedRun: GitHubWorkflowRun
    public let pullRequest: GitHubPullRequestMetadata?
    public let baseRuns: [GitHubWorkflowRun]
    public let associatedPullRequestNumbersByRunID: [Int64: [Int]]
    public let repositoryDefaultBranch: String?

    public init(
        selectedRun: GitHubWorkflowRun,
        pullRequest: GitHubPullRequestMetadata?,
        baseRuns: [GitHubWorkflowRun],
        associatedPullRequestNumbersByRunID: [Int64: [Int]],
        repositoryDefaultBranch: String? = nil
    )
}
```

`GitHubDeliveryTimelineService.timelineEvidence(...)` sets:

```swift
repositoryDefaultBranch: repository.defaultBranch
```

Every early-return/empty-evidence path preserves the repository default branch as metadata even if PR or execution correlation later cannot be established.

This metadata does not change request ordering or request counts.

## Correlation Authority

Default-branch metadata is **not** correlation evidence.

The existing correlation authority remains:

1. selected Workflow run;
2. exactly one associated Pull Request identity;
3. merged Pull Request metadata;
4. Pull Request base ref;
5. candidate base-branch Workflow runs;
6. commit → associated Pull Request evidence;
7. `GitHubWorkflowExecutionCorrelator`.

No guard may require:

```swift
pullRequest.baseRef == repositoryDefaultBranch
```

for correlation to succeed.

A Pull Request merged into `release/1.x` remains fully eligible for a correlated Delivery Timeline even when the repository default branch is `main`.

Default-branch identity changes presentation only.

## Branch Identity Comparison

A base ref is presented as the repository default branch only when both values are explicitly available and exactly equal after trimming surrounding whitespace/newlines.

Helper semantics:

```swift
private func isRepositoryDefaultBranch(
    baseRef: String,
    repositoryDefaultBranch: String?
) -> Bool {
    guard let repositoryDefaultBranch = nonEmpty(repositoryDefaultBranch) else {
        return false
    }
    return baseRef.trimmingCharacters(in: .whitespacesAndNewlines)
        == repositoryDefaultBranch
}
```

No case folding.

Examples:

```text
baseRef "main", default "main"       -> default branch
baseRef " main ", default "main"     -> default branch
baseRef "Main", default "main"       -> base branch
baseRef "release/1.x", default "main" -> base branch
default nil                           -> base branch
default "   "                         -> base branch
```

Git branch ref equality is treated as exact string identity for this presentation decision.

## Timeline Presentation

Existing correlated event:

```text
PR #49 workflow
feat/example → main

Merged
into main

Base branch · CI
Succeeded
```

When repository metadata proves `defaultBranch == "main"`:

```text
PR #49 workflow
feat/example → main

Merged
into main

Default branch · CI
Succeeded
```

When the Pull Request targets `release/1.x` and repository default branch is `main`:

```text
PR #49 workflow
feat/example → release/1.x

Merged
into release/1.x

Base branch · CI
Succeeded
```

Only the execution event title changes.

Do not change:

- event kind;
- event state;
- confidence;
- destination URL;
- event ID;
- timestamps;
- Deployment events;
- Environment enrichment;
- Workflow Job rows.

## Request Budget

No network request is added.

Existing maximum:

```text
Delivery correlation     7
Deployment enrichment    4
Environment enrichment   1
---------------------------
Total                    12
```

After this slice:

```text
Default-branch lookup     0 additional
Total                    12
```

The existing combined request-budget regression must remain exactly twelve.

Repository access inventory occurs during connection/session management and remains outside the explicit-detail feature-network budget. This slice does not add any inventory refresh during detail loading.

## Background Polling

No new polling path is added.

`GitHubActivityProvider` behavior is unchanged.

Carrying `defaultBranch` inside `GitHubRepositoryAccess` must not:

- add Activity requests;
- alter source budgets;
- change supersession behavior;
- change Actions capability preflight;
- change repository cache keys.

## Failure and Unknown Handling

```text
default_branch missing/null/blank
  -> repository remains valid
  -> Delivery correlation unchanged
  -> execution title remains "Base branch · ..."

default_branch known + exact baseRef match
  -> Delivery correlation unchanged
  -> execution title becomes "Default branch · ..."

default_branch known + baseRef mismatch
  -> Delivery correlation unchanged
  -> execution title remains "Base branch · ..."

inventory unavailable
  -> existing Activity-detail context behavior remains unchanged
  -> no fallback repository lookup is added
```

No new user-visible error state is introduced.

## Enterprise Behavior

The same repository inventory response path is used across supported GitHub endpoint families.

Rules:

- GitHub.com: normalize `default_branch` when present;
- GHE.com: normalize `default_branch` when present;
- GHES: normalize `default_branch` when present;
- older/partial GHES payload omitting the key -> `nil`;
- do not add GHES version-specific default-branch calls;
- do not infer from `master`, `main`, workflow branches, or historical activity.

The existing REST API-version policy remains unchanged.

## Security and Privacy

- no new token scope;
- no new endpoint;
- no branch write permission;
- no repository administration;
- no raw branch-list persistence;
- only one repository default-branch name is carried as ordinary repository metadata;
- no provider DTO leaks to Core/SwiftUI;
- management presentation model remains free of default-branch metadata;
- fixtures use public/synthetic repository names only;
- no private enterprise host is newly introduced by this slice.

## Visual Coverage

Add deterministic Light/Dark scenarios:

1. proven repository default branch:
   - Pull Request base: `main`
   - repository default: `main`
   - execution title: `Default branch · CI`

2. proven non-default target:
   - Pull Request base: `release/1.x`
   - repository default: `main`
   - execution title: `Base branch · CI`

Existing unknown-default fixtures continue to show `Base branch · CI`.

No width/layout changes are required.

## Testing Strategy

Development remains TDD.

### GitHubAccessClient

Test:

- repository payload `default_branch: "main"` -> `defaultBranch == "main"`;
- surrounding whitespace trims;
- explicit `null` -> `nil`;
- missing key -> `nil`;
- whitespace-only -> `nil`;
- repository mapping remains valid when field is absent;
- GitHub.com/GHE.com/GHES request behavior remains unchanged;
- repository-list request count remains unchanged.

### GitHubRepositoryAccess

Compile/source-compatibility coverage:

- old initializer call sites continue compiling because `defaultBranch` defaults to `nil`;
- equality includes the optional default branch naturally through synthesized `Equatable`.

### Runtime Repository Resolution

Test:

- Activity detail uses the repository object from access inventory;
- default branch survives into timeline loading;
- exact repository full name required;
- no matching repository -> existing `activityContextUnavailable`;
- no call through a UI-model reconstruction helper;
- no extra network request.

The old `makeRepository(option:webBaseURL:)` helper should be deleted if no caller remains.

### GitHubDeliveryTimelineService

Test:

- evidence receives `repository.defaultBranch`;
- empty/no-PR evidence still carries default branch;
- missing repository default branch remains `nil`;
- request count is identical to the existing path.

### GitHubDeliveryTimelineBuilder

Test:

- `main == main` -> `Default branch · CI`;
- trimmed ` main ` vs normalized inventory `main` -> `Default branch · CI`;
- `Main != main` -> `Base branch · CI`;
- `release/1.x != main` -> `Base branch · CI`;
- `nil` default -> `Base branch · CI`;
- correlation status/confidence are unchanged;
- correlated base run is unchanged;
- event ID/state/destination/timestamp are unchanged.

### Request Budget

Keep the existing shared-transport assertion:

```swift
#expect(featureRequests.count == 12)
```

Do not add a repository-detail endpoint to the router.

### Visual Regression

Render both new scenarios in Light and Dark.

## Expected Production Files

Likely changes after written-spec and implementation-plan approval from the clean `main` base:

- modify `Sources/SchneeBarGitHub/GitHubAccessClient.swift`;
- modify `Sources/SchneeBarGitHub/GitHubDeliveryTimelineService.swift`;
- modify `Sources/SchneeBarGitHubActivityProvider/GitHubDeliveryTimelineBuilder.swift`;
- modify `Sources/SchneeBarApp/GitHubConnectionsRuntimeModel.swift`;
- modify `Sources/SchneeBarApp/GitHubConnectionsRuntimeModel+ActivityDetail.swift`;
- extend `Sources/SchneeBarPreviewSupport/ActivityDetailFixtures.swift`;
- extend `Sources/SchneeBarVisualSnapshotCLI/main.swift`;
- optionally change Visual Harness default if the new scenario is the richest Delivery fixture;
- update `docs/DEVELOPMENT_PLAN.md`.

Likely tests:

- extend `Tests/SchneeBarGitHubTests/GitHubAccessClientTests.swift`;
- extend `Tests/SchneeBarGitHubTests/GitHubDeliveryTimelineServiceTests.swift`;
- extend `Tests/SchneeBarGitHubActivityProviderTests/GitHubDeliveryTimelineBuilderTests.swift`;
- extend `Tests/SchneeBarAppTests/GitHubConnectionsRuntimeModelActivityDetailTests.swift`;
- keep/extend the twelve-request budget regression;
- extend deterministic Visual Regression coverage.

No `SchneeBarCore` change is expected.

## Acceptance Criteria

1. Existing repository inventory normalizes explicit `default_branch` into `GitHubRepositoryAccess.defaultBranch`.
2. Missing/null/blank default branch does not invalidate repository inventory.
3. Explicit Workflow detail resolves repository access from the current runtime inventory, not a UI presentation-model reconstruction.
4. No new HTTP request is added.
5. The complete explicit-detail Delivery path remains capped at twelve feature HTTP requests.
6. Background Developer Activity polling adds zero requests and changes no behavior.
7. Default-branch metadata never establishes or rejects Delivery correlation.
8. Exact trimmed base-ref/default-branch equality is required for the **Default branch** label.
9. Comparison remains case-sensitive.
10. Non-default-target Pull Requests remain fully correlatable and show **Base branch**.
11. Unknown default branch preserves existing **Base branch** wording.
12. Timeline confidence, correlated base run, event IDs, states, URLs, and timestamps remain unchanged.
13. No `GitHubRepositoryOptionModel` default-branch field is introduced.
14. No `SchneeBarCore` schema change is introduced.
15. GitHub.com/GHE.com/GHES behavior remains compatible with missing optional metadata.
16. Light/Dark Visual Regression covers proven-default and proven-non-default branch states.
17. Final implementation head must pass CI, Visual Regression, and CodeQL before integration.

## Deferred Follow-up

- standalone Delivery history/navigation;
- persisted Delivery history;
- recovery notifications;
- branch protection/ruleset discovery;
- branch inventory;
- default-branch editing;
- paginated Environment inventory;
- custom deployment protection rules;
- broader enterprise validation.

## Self-review Checklist

Before implementation planning:

- no unresolved placeholders;
- no new repository-detail request;
- feature request cap remains twelve;
- default branch remains presentation metadata, not correlation authority;
- exact/case-sensitive comparison is explicit;
- missing metadata remains non-fatal;
- non-default PR targets remain supported;
- Activity detail uses authoritative runtime inventory;
- no UI-model round-trip for provider metadata;
- no `SchneeBarCore` change;
- Visual and enterprise behavior are explicit.

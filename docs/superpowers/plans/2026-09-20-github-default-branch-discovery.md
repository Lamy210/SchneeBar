# GitHub Default-Branch Discovery Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: execute this plan task-by-task and preserve the stacked PR dependency chain.

**Goal:** Preserve GitHub repository `default_branch` from the existing access inventory and use it only to improve Delivery Timeline presentation, with zero new feature HTTP requests and the existing 12-request explicit-detail ceiling unchanged.

**Architecture:** Extend `GitHubRepositoryAccess` with optional normalized default-branch metadata, propagate it through `GitHubDeliveryTimelineEvidence`, resolve Activity-detail repositories directly from `GitHubConnectionsRuntimeModel` access inventory instead of the UI management model, and let `GitHubDeliveryTimelineBuilder` select `Default branch · <workflow>` only on an exact proven branch-name match. Correlation authority and background Activity polling remain unchanged.

**Tech Stack:** Swift 6.3, SwiftUI/AppKit, Swift Testing, Tuist 4.203.1, GitHub REST API, GitHub Actions CI / Visual Regression / CodeQL.

**Spec:** `docs/superpowers/specs/2026-09-20-github-default-branch-discovery-design.md`

## Global Constraints

- Stacked implementation base is PR #54 / `docs/github-default-branch-discovery-design`, which itself depends on PR #53.
- No new `GET /repos/{owner}/{repo}` request.
- No default-branch polling or branch inventory.
- Complete explicit-detail Delivery feature-network ceiling remains exactly 12 requests.
- `default_branch` is presentation metadata only and must never establish, strengthen, reject, or weaken Delivery correlation.
- Non-default targets such as `release/1.x` remain fully correlatable.
- Branch comparison is exact and case-sensitive after surrounding whitespace/newline trimming.
- Missing/null/blank `default_branch` is non-fatal and normalizes to `nil`.
- Existing `GitHubRepositoryAccess` and `GitHubDeliveryTimelineEvidence` call sites remain source-compatible through defaulted initializer arguments.
- Activity detail uses authoritative runtime inventory, not a reconstruction through `GitHubRepositoryOptionModel`.
- `GitHubRepositoryOptionModel` does not gain a default-branch field.
- No `SchneeBarCore` production model change.
- No background `GitHubActivityProvider` request or behavior change.
- Production work follows TDD and preserves deterministic Light/Dark visual coverage.

---

### Task 1: Preserve `default_branch` in repository access inventory

**Files:**
- Modify: `Sources/SchneeBarGitHub/GitHubAccessClient.swift`
- Modify: `Tests/SchneeBarGitHubTests/GitHubAccessClientTests.swift`

- [ ] Add RED tests for `default_branch: "main"`, surrounding whitespace, explicit null, missing key, and whitespace-only input.
- [ ] Extend `GitHubRepositoryAccess` with `defaultBranch: String?` and a defaulted initializer argument.
- [ ] Extend `RepositoryPayload` with `default_branch`.
- [ ] Normalize missing/null/blank to `nil` and trim only surrounding whitespace/newlines.
- [ ] Prove repository inventory request count and endpoint/version behavior are unchanged.

Acceptance:
- old initializer calls compile unchanged;
- repository payload remains valid when `default_branch` is absent;
- `Main` is not lowercased to `main`.

### Task 2: Carry default-branch metadata through Delivery evidence

**Files:**
- Modify: `Sources/SchneeBarGitHub/GitHubDeliveryTimelineService.swift`
- Modify: `Tests/SchneeBarGitHubTests/GitHubDeliveryTimelineServiceTests.swift`

- [ ] Add RED tests that successful and early-return evidence preserves `repository.defaultBranch`.
- [ ] Add `repositoryDefaultBranch: String?` with a defaulted initializer argument.
- [ ] Populate it on every evidence construction path.
- [ ] Prove existing evidence request ordering and counts are unchanged.

Acceptance:
- no correlation guard depends on default-branch metadata;
- missing metadata remains `nil`;
- request count remains identical.

### Task 3: Use runtime inventory as Activity-detail repository authority

**Files:**
- Modify: `Sources/SchneeBarApp/GitHubConnectionsRuntimeModel.swift`
- Modify: `Sources/SchneeBarApp/GitHubConnectionsRuntimeModel+ActivityDetail.swift`
- Modify: `Tests/SchneeBarAppTests/GitHubConnectionsRuntimeModelActivityDetailTests.swift`

- [ ] Add RED tests proving Activity detail receives the exact inventory repository including `defaultBranch`.
- [ ] Add `repositoryAccess(profileID:fullName:)` backed by the active connection inventory.
- [ ] Require exact full-name equality and exactly one match.
- [ ] Replace `managementModel -> GitHubRepositoryOptionModel -> makeRepository` reconstruction.
- [ ] Delete `makeRepository(option:webBaseURL:)` if unused.

Acceptance:
- no fallback repository detail request;
- no presentation-model round trip;
- no match or ambiguous match keeps existing context-unavailable behavior.

### Task 4: Present proven default branch without changing correlation

**Files:**
- Modify: `Sources/SchneeBarGitHubActivityProvider/GitHubDeliveryTimelineBuilder.swift`
- Modify: `Tests/SchneeBarGitHubActivityProviderTests/GitHubDeliveryTimelineBuilderTests.swift`

- [ ] Add RED cases:
  - `main == main` -> `Default branch · CI`;
  - trimmed base ref vs normalized `main` -> `Default branch · CI`;
  - `Main != main` -> `Base branch · CI`;
  - `release/1.x != main` -> `Base branch · CI`;
  - `nil` default -> `Base branch · CI`.
- [ ] Add a private exact-match helper used only for execution-event title selection.
- [ ] Assert event ID/state/destination/timestamp/confidence and correlated base run remain unchanged.

Acceptance:
- only the execution event title changes;
- non-default target timelines remain correlated.

### Task 5: Visual fixtures, roadmap, and request-budget regression

**Files:**
- Modify: `Sources/SchneeBarPreviewSupport/ActivityDetailFixtures.swift`
- Modify: `Sources/SchneeBarVisualSnapshotCLI/main.swift`
- Modify: `docs/DEVELOPMENT_PLAN.md`
- Extend existing request-budget tests as needed.

- [ ] Add deterministic proven-default and proven-non-default Activity-detail scenarios.
- [ ] Render both scenarios in Light and Dark.
- [ ] Keep the shared explicit-detail feature request assertion exactly `12`.
- [ ] Update Phase 4 roadmap with default-branch discovery and runtime-inventory authority.
- [ ] Confirm no new route/request exists for repository detail lookup.

Acceptance:
- Visual Regression covers both branch identity outcomes;
- CI keeps 12-request ceiling;
- background polling remains unchanged.

### Task 6: Exact-head review gate

- [ ] CI Build + Test succeeds on implementation head.
- [ ] Visual Regression succeeds on implementation head.
- [ ] CodeQL succeeds on implementation head.
- [ ] No unresolved review threads.
- [ ] No requested-changes review.
- [ ] PR remains mergeable.
- [ ] Record exact implementation SHA and workflow run IDs in the implementation PR body.

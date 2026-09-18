# Delivery Timeline First Slice Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add the first user-visible, evidence-backed PR -> merge -> base-branch Delivery Timeline to Workflow Activity detail without increasing background polling cost or hiding existing job detail when timeline loading fails.

**Architecture:** Provider-neutral timeline presentation models live in `SchneeBarCore`. GitHub REST evidence loading lives in `SchneeBarGitHub`; correlation-to-presentation mapping lives in `SchneeBarGitHubActivityProvider`; `SchneeBarApp` composes timeline evidence with the existing lazy Workflow Jobs detail; `SchneeBarActivityFeature` renders the result. Timeline loading is explicit-detail-only and bounded to seven timeline requests, with `GitHubWorkflowExecutionCorrelator` remaining the correlation authority.

**Tech Stack:** Swift 6.3, SwiftUI/AppKit, Swift Testing, Tuist 4.203.1, GitHub REST API, GitHub Actions CI/Visual Regression/CodeQL.

**Spec:** `docs/superpowers/specs/2026-09-18-delivery-timeline-first-slice-design.md`

## Global Constraints

- macOS 15+ production target; Xcode 26.6 / Swift 6.3 stable baseline.
- No GitHub DTO may leak into `SchneeBarCore` or SwiftUI.
- No Delivery request may be added to normal Developer Activity polling.
- Correlation may use only evidence accepted by `GitHubWorkflowExecutionCorrelator`; branch/time/workflow-name/display-title similarity is never authoritative.
- One explicit timeline load performs at most 7 timeline list/detail requests: 1 exact run + 1 PR metadata + 1 base-branch run list + at most 4 commit->PR association requests.
- Base-run list limit is exactly 20.
- `pullRequest.baseRef` is presented as the base branch, never as the repository default branch without explicit repository metadata.
- Timeline technical failure must not hide successfully loaded Workflow Jobs.
- No persistent timeline cache, deployment/environment events, write permission, or re-run/cancel action in this slice.
- Production changes use TDD: test first, observe the intended failure, then implement the minimum production change.

---

### Task 1: Provider-neutral Delivery Timeline Core contract

**Files:**
- Create: `Sources/SchneeBarCore/DeliveryTimeline.swift`
- Modify: `Sources/SchneeBarCore/ActivityDetail.swift`
- Create: `Tests/SchneeBarCoreTests/DeliveryTimelineTests.swift`
- Modify: `Tests/SchneeBarCoreTests/ActivityDetailTests.swift`

**Interfaces:**
- Produces `DeliveryTimelineConfidence`, `DeliveryTimelineEventKind`, `DeliveryTimelineStatus`, `DeliveryTimelineEvent`, and `DeliveryTimelineSnapshot` exactly as specified.
- Extends `ActivityDetailSnapshot` with `deliveryTimeline: DeliveryTimelineSnapshot? = nil`.

- [ ] **Step 1: Write RED Core tests**

Add tests that construct a three-event timeline, assert supplied event order is preserved, assert status/confidence values remain distinct, and assert the existing `ActivityDetailSnapshot` initializer leaves `deliveryTimeline == nil` when omitted.

Representative assertion shape:

```swift
@Test
func activityDetailDefaultsDeliveryTimelineToNil() {
    let detail = ActivityDetailSnapshot(
        id: "workflow",
        repository: "snow/repo",
        title: "CI",
        summary: "1 job",
        state: .running,
        rows: []
    )
    #expect(detail.deliveryTimeline == nil)
}
```

- [ ] **Step 2: Verify RED**

Run:

```bash
mise exec -- tuist test SchneeBarCoreTests -- -skipMacroValidation CODE_SIGNING_ALLOWED=NO
```

Expected: compile/test failure because Delivery Timeline types/property do not exist.

- [ ] **Step 3: Implement minimum Core contract**

Create public enums/structs with public initializers and add the optional `deliveryTimeline` property to `ActivityDetailSnapshot` after `destinationURL`, defaulting to `nil` in its initializer. Do not add GitHub-specific names or validation heuristics.

- [ ] **Step 4: Verify GREEN**

Run the same Core test command. Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/SchneeBarCore Tests/SchneeBarCoreTests
git commit -m "feat: add delivery timeline core model"
```

### Task 2: Exact Workflow Run lookup

**Files:**
- Modify: `Sources/SchneeBarGitHub/GitHubActionsClient.swift`
- Modify: `Tests/SchneeBarGitHubTests/GitHubActionsClientTests.swift`

**Interfaces:**
- Produces:

```swift
public func workflowRun(
    id: Int64,
    repository: GitHubRepositoryAccess,
    connection: GitHubConnection,
    credential: GitHubCredential
) async throws -> GitHubWorkflowRun
```

- Keeps `GitHubWorkflowRunLoading` unchanged.

- [ ] **Step 1: Write RED client tests**

Cover exact path `/repos/{owner}/{repo}/actions/runs/{id}`, GET, API-version policy, invalid `id <= 0`, normalized Workflow Run decoding, and trusted web URL reconstruction from the configured connection/repository rather than response `html_url`.

- [ ] **Step 2: Verify RED**

```bash
mise exec -- tuist test SchneeBarGitHubTests -- -skipMacroValidation CODE_SIGNING_ALLOWED=NO
```

Expected: failure because `workflowRun(id:...)` does not exist.

- [ ] **Step 3: Implement exact lookup**

Reuse the list endpoint's `WorkflowRunPayload` decoding and mapping path. Add a dedicated invalid-run-ID error case if the existing error enum has no suitable case. Do not broaden `GitHubWorkflowRunLoading`.

- [ ] **Step 4: Verify GREEN and existing client regressions**

Run the same GitHub test target. Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/SchneeBarGitHub/GitHubActionsClient.swift Tests/SchneeBarGitHubTests/GitHubActionsClientTests.swift
git commit -m "feat: load exact GitHub workflow run"
```

### Task 3: Demand-driven GitHub timeline evidence service

**Files:**
- Create: `Sources/SchneeBarGitHub/GitHubDeliveryTimelineService.swift`
- Create: `Tests/SchneeBarGitHubTests/GitHubDeliveryTimelineServiceTests.swift`

**Interfaces:**
- Produces:

```swift
public struct GitHubDeliveryTimelineEvidence: Equatable, Sendable {
    public let selectedRun: GitHubWorkflowRun
    public let pullRequest: GitHubPullRequestMetadata?
    public let baseRuns: [GitHubWorkflowRun]
    public let associatedPullRequestNumbersByRunID: [Int64: [Int]]
}

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

- Concrete `GitHubDeliveryTimelineService` owns one session coordinator plus Actions, PR metadata, and commit->PR clients.

- [ ] **Step 1: Write RED service tests**

Use transport/credential-store stubs to prove externally visible request behavior, not private call counters. Required cases: one credential authorization path, early return for zero/multiple PR numbers, early return for unmerged PR, base query `branch=baseRef` with effective `limit=20`, same-workflow-first deterministic candidate ordering, duplicate-SHA de-duplication, first-proven-association short circuit, four-association maximum, and cancellation preventing later association requests.

- [ ] **Step 2: Verify RED**

```bash
mise exec -- tuist test SchneeBarGitHubTests -- -skipMacroValidation CODE_SIGNING_ALLOWED=NO
```

Expected: failure because service/evidence contract does not exist.

- [ ] **Step 3: Implement minimal service**

Authorize once. Load exact run. Normalize positive PR numbers. Load PR metadata only for exactly one PR. Require merged + `mergedAt`. List base-branch runs with `GitHubWorkflowRunQuery(branch: pullRequest.baseRef, limit: 20)`. Filter selected ID, exact trimmed base branch, and non-empty SHA; de-duplicate SHA; order same workflow first then `updatedAt` descending then id descending. Query at most four unique SHAs sequentially and stop when association contains the selected PR number.

- [ ] **Step 4: Verify GREEN**

Run the GitHub test target. Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/SchneeBarGitHub/GitHubDeliveryTimelineService.swift Tests/SchneeBarGitHubTests/GitHubDeliveryTimelineServiceTests.swift
git commit -m "feat: load delivery timeline evidence"
```

### Task 4: Map GitHub evidence into the Core timeline

**Files:**
- Create: `Sources/SchneeBarGitHubActivityProvider/GitHubDeliveryTimelineBuilder.swift`
- Create: `Tests/SchneeBarGitHubActivityProviderTests/GitHubDeliveryTimelineBuilderTests.swift`

**Interfaces:**
- Consumes `GitHubDeliveryTimelineEvidence` and existing `GitHubWorkflowExecutionCorrelator`.
- Produces:

```swift
public struct GitHubDeliveryTimelineBuilder: Sendable {
    public init(correlator: GitHubWorkflowExecutionCorrelator = .init())
    public func build(
        repositoryID: Int64,
        evidence: GitHubDeliveryTimelineEvidence
    ) -> DeliveryTimelineSnapshot
}
```

- [ ] **Step 1: Write RED builder tests**

Cases: merged PR + associated base run yields `[pullRequest, merge, execution]`; wrong association/branch/unmerged/ambiguous PR yields `.evidenceUnavailable`; different workflow ID remains eligible when commit association proves the PR; no branch/time/name-only promotion. Assert exact confidence for merged correlation and deterministic candidate choice.

- [ ] **Step 2: Verify RED**

```bash
mise exec -- tuist test SchneeBarGitHubActivityProviderTests -- -skipMacroValidation CODE_SIGNING_ALLOWED=NO
```

Expected: failure because builder does not exist.

- [ ] **Step 3: Implement minimum builder**

Find candidates only from evidence already loaded. For each eligible candidate call `correlateMergedPullRequest(...)` with the candidate's associated PR numbers. Select the first deterministic non-unknown result. Build trusted PR URL from normalized PR metadata and execution URL from normalized Workflow Run. Use `baseRef` wording only.

- [ ] **Step 4: Verify GREEN**

Run the provider test target. Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/SchneeBarGitHubActivityProvider/GitHubDeliveryTimelineBuilder.swift Tests/SchneeBarGitHubActivityProviderTests/GitHubDeliveryTimelineBuilderTests.swift
git commit -m "feat: build delivery timeline from GitHub evidence"
```

### Task 5: Compose best-effort timeline with existing Workflow Jobs detail

**Files:**
- Modify: `Sources/SchneeBarApp/GitHubConnectionsRuntimeModel+ActivityDetail.swift`
- Modify: `Sources/SchneeBarApp/SchneeBarApp.swift`
- Add/modify: `Tests/SchneeBarAppTests/GitHubConnectionsRuntimeModelActivityDetailTests.swift`

**Interfaces:**
- `loadActivityDetail(...)` keeps Jobs as the required branch and accepts `timelineLoader: any GitHubDeliveryTimelineLoading` plus `timelineBuilder: GitHubDeliveryTimelineBuilder`.
- Returns `ActivityDetailSnapshot` whose existing rows/summary remain job-derived and whose `deliveryTimeline` is correlated/evidence-unavailable/temporarily-unavailable.

- [ ] **Step 1: Write RED App tests**

Cover Jobs + correlated timeline, Jobs + evidence unavailable, timeline loader throws but Jobs remain successful with `.temporarilyUnavailable`, and Jobs failure still throws existing detail error. Preserve stale selection behavior through existing `ActivityRuntimeModel` tests.

- [ ] **Step 2: Verify RED**

```bash
mise exec -- tuist test SchneeBarAppTests -- -skipMacroValidation CODE_SIGNING_ALLOWED=NO
```

- [ ] **Step 3: Implement composition**

Resolve the selected repository/context once. Load jobs as today. Perform timeline load as best effort for the same connection/repository/run ID; map service errors to a Core `.temporarilyUnavailable` snapshot without exposing raw error text. Wire one `GitHubDeliveryTimelineService` in `AppDelegate` using the existing session coordinator.

- [ ] **Step 4: Verify GREEN**

Run App tests. Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/SchneeBarApp Tests/SchneeBarAppTests
git commit -m "feat: compose delivery timeline activity detail"
```

### Task 6: Render Delivery and add deterministic visual coverage

**Files:**
- Modify: `Sources/SchneeBarActivityFeature/ActivityDetailView.swift`
- Modify: `Tests/SchneeBarActivityFeatureTests/ActivityDetailViewBehaviorTests.swift`
- Modify: `Sources/SchneeBarPreviewSupport/ActivityDetailFixtures.swift`
- Modify: `Sources/SchneeBarVisualHarness/SchneeBarVisualHarnessApp.swift`
- Modify: `Sources/SchneeBarVisualSnapshotCLI/main.swift`
- Modify: `docs/DEVELOPMENT_PLAN.md`

**Interfaces:**
- Delivery section renders above Jobs when `deliveryTimeline != nil`.
- Correlated event order is not severity-sorted.
- Confidence labels are exact: `Exact correlation`, `High-confidence correlation`, `Medium-confidence correlation`, `Correlation unavailable`.

- [ ] **Step 1: Write RED feature behavior tests**

Extract pure presentation helpers where necessary so tests can assert confidence labels, event icon/state mapping, evidence-unavailable copy, and temporary-unavailable copy without snapshot-introspection hacks.

- [ ] **Step 2: Verify RED**

```bash
mise exec -- tuist test SchneeBarActivityFeatureTests -- -skipMacroValidation CODE_SIGNING_ALLOWED=NO
```

- [ ] **Step 3: Implement Delivery UI**

Render a compact `Delivery` section above Jobs. Use existing `ActivityDetailState` icon/color language. Preserve the 340-point width initially. Link only normalized trusted URLs. Never expose SHA or `default branch` wording.

- [ ] **Step 4: Add deterministic fixtures/scenes**

Add exact-correlated, evidence-unavailable, temporarily-unavailable, and correlated+matrix-job fixtures. Add Light/Dark snapshot scenarios with stable names. Do not use real private repository/token data.

- [ ] **Step 5: Update roadmap accurately**

Mark the first user-visible Phase 4 timeline slice implemented; leave deployments, default-branch discovery, standalone history, recovery notifications, and persistence incomplete.

- [ ] **Step 6: Verify feature and full regression gates**

```bash
mise exec -- tuist test SchneeBarActivityFeatureTests -- -skipMacroValidation CODE_SIGNING_ALLOWED=NO
mise exec -- tuist test -- -skipMacroValidation CODE_SIGNING_ALLOWED=NO
rm -rf _visual/candidate && mkdir -p _visual/candidate
mise exec -- tuist run SchneeBarVisualSnapshotCLI -- --output "$PWD/_visual/candidate"
```

Expected: all tests pass and deterministic visual output renders successfully.

- [ ] **Step 7: Commit**

```bash
git add Sources/SchneeBarActivityFeature Sources/SchneeBarPreviewSupport Sources/SchneeBarVisualHarness Sources/SchneeBarVisualSnapshotCLI Tests/SchneeBarActivityFeatureTests docs/DEVELOPMENT_PLAN.md
git commit -m "feat: show delivery timeline in workflow detail"
```

### Task 7: Exact-head review and merge gate

**Files:** No new production scope unless review finds a defect.

- [ ] **Step 1: Self-review spec coverage**

Check every acceptance criterion in the design against code/tests. Specifically re-check request cap, no background polling integration, GitHub DTO isolation, base/default branch wording, timeline failure isolation, and cancellation.

- [ ] **Step 2: Check PR discussion state**

Require zero unresolved review threads and no requested changes.

- [ ] **Step 3: Verify exact implementation head**

Require GitHub Actions on the exact PR head:

- CI: success;
- Visual Regression: success;
- CodeQL Build/Analyze: success when workflow scope requires execution (not merely assumed from an older head).

- [ ] **Step 4: Merge only the verified head**

Use squash merge with `expected_head_sha` equal to the verified implementation head. Do not merge if the head moved after verification.

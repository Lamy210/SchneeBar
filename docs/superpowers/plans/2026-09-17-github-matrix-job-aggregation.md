# GitHub Matrix Job Aggregation Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Collapse high-confidence matrix-like GitHub Actions job variants into one expandable Workflow detail row without inventing matrix semantics or adding network traffic.

**Architecture:** Keep grouping entirely inside `SchneeBarGitHubActivityProvider`. Extend the provider-neutral `ActivityDetailRow` with one level of children, map grouped GitHub jobs into parent/child rows, and render child-bearing rows with local SwiftUI disclosure state. Raw GitHub jobs remain the source for run-level summary counts.

**Tech Stack:** Swift 6.3, SwiftUI/AppKit, Swift Testing, Tuist 4.203.1, macOS 15+, Xcode 26.6 CI.

**Spec:** `docs/superpowers/specs/2026-09-17-github-matrix-job-aggregation-design.md`

## Global Constraints

- Do not fetch or interpret workflow YAML.
- Do not infer matrix key names or synthesize `key=value` semantics from job names.
- Add no GitHub REST requests and do not change job pagination/filter policy.
- Group only jobs sharing the exact `(runID, baseName)` key with at least two distinct opaque variant labels.
- Duplicate variant labels disable grouping for the whole bucket.
- Preserve every original job URL, failure-step detail, duration, and state as a child row.
- Keep `ActivityDetailSnapshot.summary` based on raw `[GitHubWorkflowJob]`.
- Group IDs and row ordering must be deterministic.
- Final implementation head must pass CI, Visual Regression, and CodeQL before merge.

---

### Task 1: Add provider-neutral detail children

**Files:**
- Modify: `Sources/SchneeBarCore/ActivityDetail.swift`
- Test: `Tests/SchneeBarCoreTests/ActivityDetailTests.swift`

**Interfaces:**
- Produces: `ActivityDetailRow.children: [ActivityDetailRow]`
- Preserves: existing initializer call sites via `children: [ActivityDetailRow] = []`

- [ ] **Step 1: Write the failing Core test**

Create or extend `ActivityDetailTests.swift` with:

```swift
import SchneeBarCore
import Testing

@Test
func activityDetailRowDefaultsToNoChildren() {
    let row = ActivityDetailRow(
        id: "job-1",
        title: "Build",
        state: .success
    )

    #expect(row.children.isEmpty)
}

@Test
func activityDetailRowPreservesChildren() {
    let child = ActivityDetailRow(
        id: "job-2",
        title: "macos-15",
        state: .failed
    )
    let parent = ActivityDetailRow(
        id: "group-1",
        title: "Test",
        detail: "2 variants · 1 failed",
        state: .failed,
        children: [child]
    )

    #expect(parent.children == [child])
    #expect(parent.destinationURL == nil)
}
```

- [ ] **Step 2: Run the test and verify RED**

Run:

```bash
tuist test SchneeBarCoreTests -- -skipMacroValidation CODE_SIGNING_ALLOWED=NO
```

Expected: compile failure because `ActivityDetailRow` has no `children` member/initializer argument.

- [ ] **Step 3: Implement the minimal Core model extension**

Update `ActivityDetailRow` to include:

```swift
public let children: [ActivityDetailRow]
```

and initializer parameter:

```swift
children: [ActivityDetailRow] = []
```

assigning `self.children = children`.

Do not add GitHub-specific fields or Codable conformance.

- [ ] **Step 4: Run Core tests and verify GREEN**

Run the same `tuist test SchneeBarCoreTests ...` command. Expected: all Core tests pass.

- [ ] **Step 5: Commit**

```bash
git add Sources/SchneeBarCore/ActivityDetail.swift Tests/SchneeBarCoreTests/ActivityDetailTests.swift
git commit -m "feat: add nested activity detail rows"
```

---

### Task 2: Implement conservative GitHub job variant grouping

**Files:**
- Create: `Sources/SchneeBarGitHubActivityProvider/GitHubWorkflowJobGrouper.swift`
- Create: `Tests/SchneeBarGitHubActivityProviderTests/GitHubWorkflowJobGrouperTests.swift`

**Interfaces:**
- Produces:

```swift
public struct GitHubWorkflowJobVariant: Equatable, Sendable {
    public let label: String
    public let job: GitHubWorkflowJob
}

public struct GitHubWorkflowJobVariantGroup: Equatable, Sendable {
    public let runID: Int64
    public let baseName: String
    public let variants: [GitHubWorkflowJobVariant]
}

public enum GitHubWorkflowJobPresentationEntry: Equatable, Sendable {
    case job(GitHubWorkflowJob)
    case variantGroup(GitHubWorkflowJobVariantGroup)
}

public struct GitHubWorkflowJobGrouper: Sendable {
    public init() {}
    public func entries(jobs: [GitHubWorkflowJob]) -> [GitHubWorkflowJobPresentationEntry]
}
```

- [ ] **Step 1: Write RED grouper tests**

Cover these exact cases using deterministic fake jobs:

```swift
@Test func grouperGroupsDistinctSameRunVariants()
@Test func grouperRequiresAtLeastTwoVariants()
@Test func grouperRejectsDuplicateVariantLabels()
@Test func grouperDoesNotMixRunIDs()
@Test func grouperRejectsNonTerminalSuffix()
@Test func grouperRejectsEmptyBaseOrVariant()
@Test func grouperKeepsNestedSuffixOpaque()
@Test func grouperRejectsUnbalancedSuffix()
@Test func grouperOrdersEntriesDeterministically()
```

The primary expectation must include:

```swift
#expect(group.runID == 501)
#expect(group.baseName == "Test")
#expect(group.variants.map(\.label) == ["linux", "macos"])
#expect(group.variants.map(\.job.id) == [2, 1])
```

for two jobs `Test (macos)` / `Test (linux)` with the same run ID, after deterministic variant-label sorting.

- [ ] **Step 2: Run provider tests and verify RED**

```bash
tuist test SchneeBarGitHubActivityProviderTests -- -skipMacroValidation CODE_SIGNING_ALLOWED=NO
```

Expected: compile failure because `GitHubWorkflowJobGrouper` and presentation-entry types do not exist.

- [ ] **Step 3: Implement terminal suffix parsing**

In `GitHubWorkflowJobGrouper.swift`, add a private parser that:

```swift
private func parseVariantName(_ rawName: String) -> GitHubWorkflowJobVariantName?
```

Algorithm:

1. trim surrounding whitespace;
2. require final `)`;
3. scan Unicode scalar/character indices backward from the final `)` maintaining parenthesis depth;
4. stop when depth returns to zero at the matching `(`;
5. require the character immediately before that `(` to be exactly one ASCII space;
6. trim base and suffix interior;
7. return nil for empty base/suffix or unbalanced parentheses.

Do not split or interpret the suffix contents.

- [ ] **Step 4: Implement grouping by `(runID, baseName)`**

Build candidate buckets keyed by a private `Hashable` key:

```swift
private struct GroupKey: Hashable {
    let runID: Int64
    let baseName: String
}
```

For each bucket:

- group only when count >= 2;
- require `Set(labels).count == count`;
- otherwise emit all jobs as `.job` entries;
- sort variants by `label`, then job ID;
- preserve non-candidate jobs as `.job`.

Sort output deterministically by a presentation key based on base/full name, then stable ID. State-priority ordering remains mapper responsibility in Task 3.

- [ ] **Step 5: Run provider tests and verify GREEN**

Run the same provider-test command. Expected: all grouper tests pass.

- [ ] **Step 6: Commit**

```bash
git add Sources/SchneeBarGitHubActivityProvider/GitHubWorkflowJobGrouper.swift Tests/SchneeBarGitHubActivityProviderTests/GitHubWorkflowJobGrouperTests.swift
git commit -m "feat: group GitHub workflow job variants"
```

---

### Task 3: Map groups into deterministic parent/child detail rows

**Files:**
- Modify: `Sources/SchneeBarGitHubActivityProvider/GitHubActivityJobDetailMapper.swift`
- Modify: `Tests/SchneeBarGitHubActivityProviderTests/GitHubActivityJobDetailMapperTests.swift`

**Interfaces:**
- Consumes: `GitHubWorkflowJobGrouper.entries(jobs:)`
- Produces: grouped `ActivityDetailRow` parents with original jobs as children

- [ ] **Step 1: Add RED mapper tests**

Add tests covering:

```swift
@Test func jobDetailMapperMapsFailedVariantGroup()
@Test func jobDetailMapperMapsRunningAndWaitingPrecedence()
@Test func jobDetailMapperMapsAllSuccessGroup()
@Test func jobDetailMapperMapsCancelledOnlyGroupAsNeutral()
@Test func jobDetailMapperPrefersSuccessOverNeutral()
@Test func jobDetailMapperPreservesRawSummaryCounts()
```

For a failed group assert:

```swift
#expect(snapshot.summary == "3/3 jobs · 1 failed")
#expect(snapshot.rows.count == 1)
let group = try #require(snapshot.rows.first)
#expect(group.title == "Test")
#expect(group.detail == "3 variants · 1 failed")
#expect(group.state == .failed)
#expect(group.destinationURL == nil)
#expect(group.children.map(\.title) == ["macos", "linux", "windows"] /* adjusted for priority+label order */)
#expect(group.children.first?.detail == "Failed at Test")
#expect(group.children.first?.destinationURL == failedJob.webURL)
```

Use labels/state fixtures so the expected child order exercises `failed > running > waiting > success > neutral`, then label, then job ID.

- [ ] **Step 2: Run provider tests and verify RED**

Run:

```bash
tuist test SchneeBarGitHubActivityProviderTests -- -skipMacroValidation CODE_SIGNING_ALLOWED=NO
```

Expected: tests fail because mapper still emits one row per job.

- [ ] **Step 3: Inject the grouper and refactor row helpers**

Change mapper initialization to:

```swift
private let grouper: GitHubWorkflowJobGrouper

public init(grouper: GitHubWorkflowJobGrouper = GitHubWorkflowJobGrouper()) {
    self.grouper = grouper
}
```

Keep raw-job `GitHubWorkflowJobSummary(jobs:)` exactly where it is.

Extract reusable helpers for:

```swift
private func makeJobDetailRow(_ job: GitHubWorkflowJob, title: String? = nil) -> ActivityDetailRow
private func jobState(_ job: GitHubWorkflowJob) -> ActivityDetailState
private func detailPriority(_ state: ActivityDetailState) -> Int
```

- [ ] **Step 4: Map presentation entries**

Map `.job` using existing behavior.

Map `.variantGroup` to a parent where:

```swift
id = "github-job-group:\(group.runID):\(group.baseName)"
title = group.baseName
destinationURL = nil
children = group.variants.map { variant in
    makeJobDetailRow(variant.job, title: variant.label)
}
```

Sort children by state priority, then variant label, then job ID.

Parent state is the highest-priority child state using:

```text
failed > running > waiting > success > neutral
```

Parent detail starts with `"N variants"` and appends non-zero counts in this exact order: failed, running, waiting, cancelled.

Count cancelled using raw child conclusions, not `.neutral` state, so skipped/stale/neutral do not inflate cancelled count.

- [ ] **Step 5: Sort top-level mapped rows**

Sort groups and single jobs using existing state priority first. Within the same state, use row title then row ID. This preserves current failure/running/waiting visibility while making grouping deterministic.

- [ ] **Step 6: Run provider tests and verify GREEN**

Run provider tests. Expected: existing mapper tests plus new grouping tests all pass.

- [ ] **Step 7: Commit**

```bash
git add Sources/SchneeBarGitHubActivityProvider/GitHubActivityJobDetailMapper.swift Tests/SchneeBarGitHubActivityProviderTests/GitHubActivityJobDetailMapperTests.swift
git commit -m "feat: aggregate workflow job variants in detail"
```

---

### Task 4: Render expandable group rows and add deterministic visuals

**Files:**
- Modify: `Sources/SchneeBarActivityFeature/ActivityDetailView.swift`
- Test: `Tests/SchneeBarActivityFeatureTests/ActivityDetailViewBehaviorTests.swift`
- Modify: `Sources/SchneeBarPreviewSupport/ActivityDetailFixtures.swift`
- Modify: `Sources/SchneeBarVisualSnapshotCLI/main.swift`
- Modify: `Sources/SchneeBarVisualHarness/SchneeBarVisualHarnessApp.swift`

**Interfaces:**
- Consumes: `ActivityDetailRow.children`
- Behavior: childless rows retain existing Link behavior; child-bearing rows render local disclosure parent with no destination URL

- [ ] **Step 1: Add RED feature behavior tests**

Test pure presentation predicates/helpers rather than UI pixel internals. Add internal/public helper only if needed:

```swift
@Test func groupRowIsLocallyExpandable()
@Test func childlessRowIsNotLocallyExpandable()
@Test func groupParentHasNoExternalDestination()
```

Fixture expectation:

```swift
#expect(group.children.count == 3)
#expect(group.destinationURL == nil)
#expect(group.children.allSatisfy { $0.destinationURL != nil })
```

- [ ] **Step 2: Run ActivityFeature tests and verify RED**

```bash
tuist test SchneeBarActivityFeatureTests -- -skipMacroValidation CODE_SIGNING_ALLOWED=NO
```

Expected: failure because child-bearing presentation is not implemented.

- [ ] **Step 3: Implement disclosure rendering**

In `ActivityDetailView`:

- preserve current row implementation for `children.isEmpty`;
- render child-bearing rows with `DisclosureGroup` or equivalent local `@State` disclosure state;
- show the parent state icon/title/detail while collapsed;
- do not wrap the parent in `Link`;
- render children indented using the same state icon/detail/link semantics as normal rows;
- default groups to collapsed;
- keep expansion state view-local and non-persistent;
- ensure tapping disclosure does not open a child URL.

Keep existing width and 360pt scroll-height cap unless snapshots demonstrate clipping.

- [ ] **Step 4: Add deterministic matrix detail fixtures**

Extend `ActivityDetailFixtures.swift` with separate snapshots for:

```swift
matrixSuccess
matrixFailure
```

`matrixSuccess` must contain one collapsed success group and one normal single row. `matrixFailure` must contain a failed parent with at least three children, including one failed child with a trusted fake GitHub job URL.

Use fictional deterministic URLs and no user/private data.

- [ ] **Step 5: Add Visual Snapshot CLI scenes**

Add output scenarios named exactly:

```text
matrix-success-light
matrix-failure-light
matrix-failure-dark
```

Render `ActivityDetailView` with deterministic surface style. Do not add production-only expanded-state hooks just for snapshots.

- [ ] **Step 6: Add matching Visual Harness entries**

Expose the same fixtures in the manual visual harness so local inspection matches CI fixtures.

- [ ] **Step 7: Run feature tests and full CI-equivalent tests**

```bash
tuist test SchneeBarActivityFeatureTests -- -skipMacroValidation CODE_SIGNING_ALLOWED=NO
tuist test -- -skipMacroValidation CODE_SIGNING_ALLOWED=NO
```

Expected: all tests pass.

- [ ] **Step 8: Run/render visual candidates**

Use the repository Visual Regression workflow-equivalent snapshot command defined by `Sources/SchneeBarVisualSnapshotCLI/main.swift` / `.github/workflows/visual.yml`, and verify all three new PNG scenes are generated with no clipping or missing disclosure affordance.

- [ ] **Step 9: Commit**

```bash
git add Sources/SchneeBarActivityFeature/ActivityDetailView.swift Tests/SchneeBarActivityFeatureTests/ActivityDetailViewBehaviorTests.swift Sources/SchneeBarPreviewSupport/ActivityDetailFixtures.swift Sources/SchneeBarVisualSnapshotCLI/main.swift Sources/SchneeBarVisualHarness/SchneeBarVisualHarnessApp.swift
git commit -m "feat: show expandable workflow job variant groups"
```

---

### Task 5: Update roadmap and complete exact-head verification

**Files:**
- Modify: `docs/DEVELOPMENT_PLAN.md`
- Update PR description/checklist

**Interfaces:**
- Produces: documented Phase 3 completion evidence and merge-ready exact head

- [ ] **Step 1: Update the development plan**

Under Phase 3 Implemented, add:

```text
- conservative matrix-like Workflow job variant aggregation with expandable child jobs
```

Remove matrix-job aggregation from the Phase 3 `Next` list and make superseded-run handling the first remaining hardening item.

- [ ] **Step 2: Run full CI-equivalent verification on the final head**

```bash
tuist generate
tuist build -- -skipMacroValidation CODE_SIGNING_ALLOWED=NO
tuist test -- -skipMacroValidation CODE_SIGNING_ALLOWED=NO
```

Expected: all commands exit 0.

- [ ] **Step 3: Verify Visual Regression on the exact same head**

Confirm the GitHub `Visual Regression` workflow completes successfully for the final implementation SHA and includes the three new matrix scenes.

- [ ] **Step 4: Verify CodeQL on the exact same head**

Mark the PR Ready if CodeQL is draft-gated, then confirm `Generate Xcode project`, `Initialize CodeQL`, `Build for analysis`, and `Analyze` all succeed for the exact final SHA.

- [ ] **Step 5: Review the final diff**

Confirm:

- no REST client/service files changed;
- no workflow YAML fetching exists;
- no inferred matrix key strings are generated;
- child URLs remain the normalized `GitHubWorkflowJob.webURL` values;
- review threads are resolved/empty;
- PR is mergeable.

- [ ] **Step 6: Commit docs and merge**

```bash
git add docs/DEVELOPMENT_PLAN.md
git commit -m "docs: mark matrix job aggregation implemented"
```

Squash merge only after CI, Visual Regression, and CodeQL are all green on the exact PR head.

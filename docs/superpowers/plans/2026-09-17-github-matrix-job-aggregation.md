# GitHub Matrix Job Aggregation Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Collapse high-confidence matrix-like GitHub Actions job variants into one expandable Workflow detail row without inventing matrix semantics or adding network traffic.

**Architecture:** Keep grouping inside `SchneeBarGitHubActivityProvider`. Extend provider-neutral `ActivityDetailRow` with one level of children, map grouped GitHub jobs into parent/child rows, and render child-bearing rows with local SwiftUI disclosure state. Raw GitHub jobs remain the source for run-level summary counts.

**Tech Stack:** Swift 6.3, SwiftUI/AppKit, Swift Testing, Tuist 4.203.1, macOS 15+, Xcode 26.6 CI.

**Spec:** `docs/superpowers/specs/2026-09-17-github-matrix-job-aggregation-design.md`

## Global Constraints

- Do not fetch or interpret workflow YAML.
- Do not infer matrix key names or synthesize `key=value` semantics from job names.
- Add no GitHub REST requests and do not change job pagination/filter policy.
- Group only jobs sharing the exact `(runID, baseName)` key with at least two distinct opaque variant labels.
- Duplicate variant labels disable grouping for the entire bucket.
- Preserve every original job URL, failure-step detail, duration, and state as a child row.
- Keep `ActivityDetailSnapshot.summary` based on raw `[GitHubWorkflowJob]`.
- Group IDs and ordering must be deterministic.
- Final implementation head must pass CI, Visual Regression, and CodeQL before merge.

---

### Task 1: Add provider-neutral detail children

**Files:**
- Modify: `Sources/SchneeBarCore/ActivityDetail.swift`
- Create: `Tests/SchneeBarCoreTests/ActivityDetailTests.swift` if absent; otherwise extend it.

**Produces:** `ActivityDetailRow.children: [ActivityDetailRow]` with initializer default `[]`.

- [ ] Write RED tests:

```swift
import SchneeBarCore
import Testing

@Test func activityDetailRowDefaultsToNoChildren() {
    let row = ActivityDetailRow(id: "job-1", title: "Build", state: .success)
    #expect(row.children.isEmpty)
}

@Test func activityDetailRowPreservesChildren() {
    let child = ActivityDetailRow(id: "job-2", title: "macos-15", state: .failed)
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

- [ ] Run:

```bash
tuist test SchneeBarCoreTests -- -skipMacroValidation CODE_SIGNING_ALLOWED=NO
```

Expected RED: `ActivityDetailRow` has no `children` member/argument.

- [ ] Implement `public let children: [ActivityDetailRow]` and add `children: [ActivityDetailRow] = []` to the initializer, assigning `self.children = children`.
- [ ] Re-run the same test command and require GREEN.
- [ ] Commit: `feat: add nested activity detail rows`.

---

### Task 2: Implement conservative GitHub job variant grouping

**Files:**
- Create: `Sources/SchneeBarGitHubActivityProvider/GitHubWorkflowJobGrouper.swift`
- Create: `Tests/SchneeBarGitHubActivityProviderTests/GitHubWorkflowJobGrouperTests.swift`

**Produces:**

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

- [ ] Write RED tests for: 2/3 same-base variants, one candidate only, duplicate labels, different bases, different run IDs, non-terminal suffix, empty base/suffix, balanced nested suffix, unbalanced suffix, deterministic ordering.

Primary expectation for `Test (macos)` id 1 and `Test (linux)` id 2, run 501:

```swift
#expect(group.runID == 501)
#expect(group.baseName == "Test")
#expect(group.variants.map(\.label) == ["linux", "macos"])
#expect(group.variants.map(\.job.id) == [2, 1])
```

- [ ] Run `tuist test SchneeBarGitHubActivityProviderTests -- -skipMacroValidation CODE_SIGNING_ALLOWED=NO`; expected RED because grouper types are undefined.
- [ ] Implement terminal suffix parser: trim; require final `)`; scan backward balancing parentheses; require one ASCII space before matching `(`; trim/reject empty parts; keep suffix opaque.
- [ ] Group using private `GroupKey(runID: Int64, baseName: String)`. Group only count >= 2 with distinct labels; otherwise emit original jobs. Sort variants by label then job ID.
- [ ] Re-run provider tests and require GREEN.
- [ ] Commit: `feat: group GitHub workflow job variants`.

---

### Task 3: Map groups into parent/child detail rows

**Files:**
- Modify: `Sources/SchneeBarGitHubActivityProvider/GitHubActivityJobDetailMapper.swift`
- Modify: `Tests/SchneeBarGitHubActivityProviderTests/GitHubActivityJobDetailMapperTests.swift`

- [ ] Add RED tests for failed, running, waiting, all-success, cancelled-only, success+cancelled, raw-summary preservation, child URL/failure detail, and child sorting.

For failed `macos`, running `linux`, successful `windows`, require:

```swift
#expect(snapshot.summary == "2/3 jobs · 1 failed · 1 running")
let group = try #require(snapshot.rows.first)
#expect(group.title == "Test")
#expect(group.detail == "3 variants · 1 failed · 1 running")
#expect(group.state == .failed)
#expect(group.destinationURL == nil)
#expect(group.children.map(\.title) == ["macos", "linux", "windows"])
#expect(group.children.map(\.state) == [.failed, .running, .success])
#expect(group.children[0].detail == "Failed at Test")
#expect(group.children[0].destinationURL == failedJob.webURL)
```

- [ ] Run provider tests; expected RED because mapper still emits one row/job.
- [ ] Inject `GitHubWorkflowJobGrouper` via defaulted initializer and keep `GitHubWorkflowJobSummary(jobs:)` on raw jobs.
- [ ] Reuse helpers `makeJobDetailRow(_:title:)`, `jobState(_:)`, `detailPriority(_:)`.
- [ ] Map group parent ID as `github-job-group:<runID>:<baseName>`, nil destination, child rows titled by opaque label. Sort children `failed > running > waiting > success > neutral`, then label, then job ID.
- [ ] Build parent detail `N variants` plus nonzero failed/running/waiting/cancelled counts in that order; cancelled comes only from raw `.cancelled` conclusions.
- [ ] Sort top-level rows by state priority, title, ID.
- [ ] Re-run provider tests and require GREEN.
- [ ] Commit: `feat: aggregate workflow job variants in detail`.

---

### Task 4: Render expandable rows and deterministic visuals

**Files:**
- Modify: `Sources/SchneeBarActivityFeature/ActivityDetailView.swift`
- Create: `Tests/SchneeBarActivityFeatureTests/ActivityDetailViewBehaviorTests.swift`
- Modify: `Sources/SchneeBarPreviewSupport/ActivityDetailFixtures.swift`
- Modify: `Sources/SchneeBarVisualSnapshotCLI/main.swift`
- Modify: `Sources/SchneeBarVisualHarness/SchneeBarVisualHarnessApp.swift`

**Produces:**

```swift
enum ActivityDetailRowInteraction: Equatable {
    case disclosure
    case link(URL)
    case none
}

func activityDetailRowInteraction(_ row: ActivityDetailRow) -> ActivityDetailRowInteraction {
    if !row.children.isEmpty { return .disclosure }
    if let destinationURL = row.destinationURL { return .link(destinationURL) }
    return .none
}
```

`ActivityDetailView` uses this classifier.

- [ ] Write RED tests `groupRowUsesDisclosureInteraction`, `childlessDestinationRowUsesLinkInteraction`, and `childlessDestinationlessRowUsesNoInteraction`; verify grouped children with URLs classify as links.
- [ ] Run `tuist test SchneeBarActivityFeatureTests -- -skipMacroValidation CODE_SIGNING_ALLOWED=NO`; expected RED because classifier is undefined.
- [ ] Implement classifier and UI: disclosure parent with state/title/detail, collapsed by default, no parent link; child rows indented and rendered through same classifier; expansion view-local/nonpersistent; keep 360pt scroll cap.
- [ ] Add deterministic `matrixSuccess` and `matrixFailure` detail fixtures. Failure fixture has 3 children and one failed child URL.
- [ ] Add snapshots exactly `matrix-success-light`, `matrix-failure-light`, `matrix-failure-dark`; no production-only expansion hook.
- [ ] Add matching manual Visual Harness entries.
- [ ] Run:

```bash
tuist test SchneeBarActivityFeatureTests -- -skipMacroValidation CODE_SIGNING_ALLOWED=NO
tuist test -- -skipMacroValidation CODE_SIGNING_ALLOWED=NO
mkdir -p _visual/candidate
tuist run SchneeBarVisualSnapshotCLI -- --output "$PWD/_visual/candidate"
```

Require all tests pass and the three new PNGs exist.
- [ ] Commit: `feat: show expandable workflow job variant groups`.

---

### Task 5: Roadmap and exact-head merge gates

**Files:**
- Modify: `docs/DEVELOPMENT_PLAN.md`
- Update implementation PR description/checklist.

- [ ] Add Phase 3 Implemented item `conservative matrix-like Workflow job variant aggregation with expandable child jobs`; remove matrix aggregation from Next and put superseded-run handling first.
- [ ] Run final `tuist generate`, `tuist build -- -skipMacroValidation CODE_SIGNING_ALLOWED=NO`, and `tuist test -- -skipMacroValidation CODE_SIGNING_ALLOWED=NO` on final head.
- [ ] Confirm Visual Regression succeeds on the same SHA and includes new matrix scenes.
- [ ] Mark PR Ready and confirm CodeQL on same SHA has successful Generate, Initialize, Build for analysis, Analyze.
- [ ] Final diff review: no REST client/service changes, no workflow-YAML fetch, no synthesized matrix keys, child URLs unchanged, no unresolved review threads, PR mergeable.
- [ ] Commit docs as `docs: mark matrix job aggregation implemented`.
- [ ] Squash merge only after CI, Visual Regression, and CodeQL are all green on exact PR head.

## Self-Review Result

- Spec coverage: all acceptance criteria map to Tasks 1-5.
- Placeholder scan: no `TODO`, `TBD`, "similar to", or open-ended implementation step remains.
- Type consistency: grouper, group model, `children`, interaction classifier, mapper signatures, scene names, and gate commands are consistent across tasks.

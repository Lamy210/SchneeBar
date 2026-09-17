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

- [ ] Implement:

```swift
public let children: [ActivityDetailRow]
```

and add `children: [ActivityDetailRow] = []` to the initializer, assigning `self.children = children`.

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

Primary grouped expectation for jobs `Test (macos)` id 1 and `Test (linux)` id 2, both run 501:

```swift
#expect(group.runID == 501)
#expect(group.baseName == "Test")
#expect(group.variants.map(\.label) == ["linux", "macos"])
#expect(group.variants.map(\.job.id) == [2, 1])
```

- [ ] Run:

```bash
tuist test SchneeBarGitHubActivityProviderTests -- -skipMacroValidation CODE_SIGNING_ALLOWED=NO
```

Expected RED: grouper/presentation-entry types are undefined.

- [ ] Implement private suffix parsing:
  1. trim full name;
  2. require final `)`;
  3. scan backward balancing nested parentheses to matching `(`;
  4. require exactly one ASCII space immediately before that `(`;
  5. trim base and suffix;
  6. reject empty/unbalanced input;
  7. keep suffix opaque.

- [ ] Group with private key:

```swift
private struct GroupKey: Hashable {
    let runID: Int64
    let baseName: String
}
```

Group only if count >= 2 and all labels are distinct. Otherwise emit original `.job` entries. Sort variants by label then job ID. Preserve every noncandidate job.

- [ ] Re-run provider tests and require GREEN.
- [ ] Commit: `feat: group GitHub workflow job variants`.

---

### Task 3: Map groups into parent/child detail rows

**Files:**
- Modify: `Sources/SchneeBarGitHubActivityProvider/GitHubActivityJobDetailMapper.swift`
- Modify: `Tests/SchneeBarGitHubActivityProviderTests/GitHubActivityJobDetailMapperTests.swift`

**Consumes:** `GitHubWorkflowJobGrouper.entries(jobs:)`.

- [ ] Add RED mapper tests for failed, running, waiting, all-success, cancelled-only, success+cancelled, raw-summary preservation, child URL/failure detail, and child sorting.

Use a failed `macos` child, running `linux` child, and successful `windows` child and require:

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

- [ ] Inject:

```swift
private let grouper: GitHubWorkflowJobGrouper

public init(grouper: GitHubWorkflowJobGrouper = GitHubWorkflowJobGrouper()) {
    self.grouper = grouper
}
```

Keep `GitHubWorkflowJobSummary(jobs:)` based on raw jobs.

- [ ] Extract/reuse:

```swift
private func makeJobDetailRow(_ job: GitHubWorkflowJob, title: String? = nil) -> ActivityDetailRow
private func jobState(_ job: GitHubWorkflowJob) -> ActivityDetailState
private func detailPriority(_ state: ActivityDetailState) -> Int
```

- [ ] Map group parent:

```swift
ActivityDetailRow(
    id: "github-job-group:\(group.runID):\(group.baseName)",
    title: group.baseName,
    detail: groupDetail,
    state: aggregateState,
    destinationURL: nil,
    children: children
)
```

Children use variant label as title and retain each original `GitHubWorkflowJob.webURL`. Sort children by `failed > running > waiting > success > neutral`, then label, then job ID.

Parent detail is `N variants`, then non-zero `failed`, `running`, `waiting`, `cancelled` counts in that order. Count cancelled from raw conclusion `.cancelled`; do not count all neutral rows as cancelled.

Top-level rows sort by the same state priority, then title, then ID.

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

**Produces:** exact internal interaction classifier:

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

`ActivityDetailView` must use this classifier, so the unit test and rendered behavior exercise the same decision.

- [ ] Write RED feature tests:

```swift
@Test func groupRowUsesDisclosureInteraction()
@Test func childlessDestinationRowUsesLinkInteraction()
@Test func childlessDestinationlessRowUsesNoInteraction()
```

Require a group with children and a nil parent URL to classify as `.disclosure`; require each linked child to classify as `.link(childURL)`.

- [ ] Run:

```bash
tuist test SchneeBarActivityFeatureTests -- -skipMacroValidation CODE_SIGNING_ALLOWED=NO
```

Expected RED: `ActivityDetailRowInteraction` / classifier undefined.

- [ ] Implement the classifier and use it in `ActivityDetailView`.
  - `.disclosure`: render parent state icon/title/detail inside `DisclosureGroup`, collapsed by default, no external-link affordance on parent.
  - `.link(url)`: preserve existing `Link` row behavior.
  - `.none`: preserve existing plain row behavior.
  - Render child rows indented through the same classifier; design data is one level deep.
  - Keep expansion state view-local/nonpersistent and the 360pt scroll cap.

- [ ] Extend `ActivityDetailFixtures.swift` with `matrixSuccess` and `matrixFailure`. `matrixFailure` has a failed parent with 3 children and one failed child URL. `matrixSuccess` has one success group plus one ordinary single row.

- [ ] Add snapshot outputs named exactly:

```text
matrix-success-light
matrix-failure-light
matrix-failure-dark
```

Do not add a production-only expanded-state hook; collapsed group layout is the visual contract.

- [ ] Add matching manual Visual Harness entries.

- [ ] Run:

```bash
tuist test SchneeBarActivityFeatureTests -- -skipMacroValidation CODE_SIGNING_ALLOWED=NO
tuist test -- -skipMacroValidation CODE_SIGNING_ALLOWED=NO
mkdir -p _visual/candidate
tuist run SchneeBarVisualSnapshotCLI -- --output "$PWD/_visual/candidate"
```

Require tests to pass and the three new PNGs to exist in `_visual/candidate`.

- [ ] Commit: `feat: show expandable workflow job variant groups`.

---

### Task 5: Roadmap and exact-head merge gates

**Files:**
- Modify: `docs/DEVELOPMENT_PLAN.md`
- Update implementation PR description/checklist.

- [ ] Under Phase 3 Implemented add:

```text
- conservative matrix-like Workflow job variant aggregation with expandable child jobs
```

Remove matrix aggregation from `Next`; superseded-run handling becomes the first remaining hardening item.

- [ ] Run final CI-equivalent commands on the final implementation head:

```bash
tuist generate
tuist build -- -skipMacroValidation CODE_SIGNING_ALLOWED=NO
tuist test -- -skipMacroValidation CODE_SIGNING_ALLOWED=NO
```

- [ ] Confirm GitHub `Visual Regression` succeeds on that same SHA and produces the matrix scenes.
- [ ] Mark PR Ready and confirm CodeQL on the same SHA has successful `Generate Xcode project`, `Initialize CodeQL`, `Build for analysis`, and `Analyze` steps.
- [ ] Review final diff: no REST client/service changes, no workflow-YAML fetch, no synthesized matrix keys, children keep normalized job URLs, no unresolved review threads, PR mergeable.
- [ ] Commit docs as `docs: mark matrix job aggregation implemented`.
- [ ] Squash merge only after CI, Visual Regression, and CodeQL are all green on the exact PR head.

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

**Files:** `Sources/SchneeBarCore/ActivityDetail.swift`, `Tests/SchneeBarCoreTests/ActivityDetailTests.swift`.

- [ ] RED: test `children` default `[]` and preservation.
- [ ] GREEN: add `public let children: [ActivityDetailRow]` and initializer default `[]`.
- [ ] Verify `tuist test SchneeBarCoreTests -- -skipMacroValidation CODE_SIGNING_ALLOWED=NO`.
- [ ] Commit `feat: add nested activity detail rows`.

### Task 2: Implement conservative GitHub job variant grouping

**Files:** create `Sources/SchneeBarGitHubActivityProvider/GitHubWorkflowJobGrouper.swift`, create `Tests/SchneeBarGitHubActivityProviderTests/GitHubWorkflowJobGrouperTests.swift`.

**Types:** `GitHubWorkflowJobVariant`, `GitHubWorkflowJobVariantGroup(runID, baseName, variants)`, `GitHubWorkflowJobPresentationEntry`, `GitHubWorkflowJobGrouper.entries(jobs:)`.

- [ ] RED tests: same-base variants, singleton, duplicate labels, different bases/run IDs, terminal-only suffix, empty/unbalanced rejection, nested suffix opacity, deterministic ordering.
- [ ] Parser: trim, require final `)`, backward balanced scan, require one ASCII space before suffix `(`, trim/reject empty, keep suffix opaque.
- [ ] Group by `(runID, baseName)` only when count >= 2 and labels distinct. Sort variants label then job ID.
- [ ] Verify `tuist test SchneeBarGitHubActivityProviderTests -- -skipMacroValidation CODE_SIGNING_ALLOWED=NO`.
- [ ] Commit `feat: group GitHub workflow job variants`.

### Task 3: Map groups into parent/child detail rows

**Files:** `GitHubActivityJobDetailMapper.swift`, `GitHubActivityJobDetailMapperTests.swift`.

- [ ] RED tests for failed/running/waiting/success/neutral precedence, cancelled count, raw summary, child URL/failure detail/sort.
- [ ] Inject default `GitHubWorkflowJobGrouper`; keep `GitHubWorkflowJobSummary(jobs:)` on raw jobs.
- [ ] Group parent: deterministic run/base ID, nil destination, opaque-label children retaining job URL.
- [ ] Parent detail: `N variants`, then nonzero failed/running/waiting/cancelled; cancelled from raw conclusion only.
- [ ] Sort state priority then title/ID; children state priority then label/job ID.
- [ ] Verify provider tests GREEN.
- [ ] Commit `feat: aggregate workflow job variants in detail`.

### Task 4: Render expandable rows and deterministic visuals

**Files:** `ActivityDetailView.swift`, new `ActivityDetailViewBehaviorTests.swift`, `ActivityDetailFixtures.swift`, Visual Snapshot CLI, Visual Harness.

**Interaction contract:** internal `ActivityDetailRowInteraction { disclosure, link(URL), none }` and `activityDetailRowInteraction(_:)`; child-bearing rows classify disclosure before destination URL.

- [ ] RED interaction tests.
- [ ] UI: collapsed `DisclosureGroup` parent, no parent link, linked indented children, view-local expansion, existing scroll cap.
- [ ] Add deterministic `matrixSuccess` and `matrixFailure` fixtures.
- [ ] Add scenes exactly `matrix-success-light`, `matrix-failure-light`, `matrix-failure-dark` and matching harness entries.
- [ ] Verify:

```bash
tuist test SchneeBarActivityFeatureTests -- -skipMacroValidation CODE_SIGNING_ALLOWED=NO
tuist test -- -skipMacroValidation CODE_SIGNING_ALLOWED=NO
mkdir -p _visual/candidate
tuist run SchneeBarVisualSnapshotCLI -- --output "$PWD/_visual/candidate"
```

- [ ] Commit `feat: show expandable workflow job variant groups`.

### Task 5: Roadmap and exact-head merge gates

- [ ] Update `docs/DEVELOPMENT_PLAN.md`: matrix aggregation implemented; superseded-run handling becomes first Next item.
- [ ] Final exact-head `tuist generate`, build, full test.
- [ ] Same SHA Visual Regression success with matrix scenes.
- [ ] Ready PR; same SHA CodeQL Generate/Initialize/Build/Analyze success.
- [ ] Final diff: no REST client/service changes, no YAML fetch, no synthetic matrix keys, child URLs preserved, no unresolved threads, PR mergeable.
- [ ] Commit docs `docs: mark matrix job aggregation implemented` and squash merge only after all gates green.

## Self-Review Result

- Spec coverage: all acceptance criteria map to Tasks 1-5.
- Placeholder scan: no open-ended implementation step remains.
- Type consistency: grouper, group model, `children`, interaction classifier, mapper signatures, scene names, and gate commands are aligned.
- Authorization: user delegated design review and authorized implementation when no blocking issue remained; self-review found none.

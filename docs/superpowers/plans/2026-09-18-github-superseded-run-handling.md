# GitHub Superseded Run Handling Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Remove proven-obsolete pull-request workflow runs from Developer Activity and Workflow-derived Check evidence without suppressing ambiguous, branch-only, or same-SHA runs.

**Architecture:** Add one pure `GitHubWorkflowRunSupersessionResolver` inside `SchneeBarGitHubActivityProvider`. `GitHubActivityProvider.loadWorkflowRepositories` invokes it exactly once after a successful Workflow API load and feeds only `currentRuns` to both `GitHubWorkflowActivityMapper` and `GitHubWorkflowEvidence`, preserving existing cache, request-budget, generation, and UI behavior.

**Tech Stack:** Swift 6.3, Swift Testing, Swift Concurrency, Tuist 4.203.1, Xcode 26.6, GitHub Actions on `macos-26`.

**Spec:** `docs/superpowers/specs/2026-09-18-github-superseded-run-handling-design.md`

## Global Constraints

- Supersession lane is exactly `(workflowID, event, single positive pullRequestNumber)` and is repository-scoped by invocation.
- Only a strictly lower `runNumber` with a different non-empty normalized `headSHA` may be superseded.
- Same-SHA runs are retained even when their `runNumber` is older.
- Zero/multiple PR-number runs, duplicate maximum `runNumber` lanes, empty normalized SHAs, different workflow IDs, different events, and branch-only runs are retained.
- A newest cancelled/skipped run still supersedes an obsolete different-SHA run.
- Superseded runs feed neither Workflow Inbox activity nor Workflow-derived Check evidence.
- Review-derived Check candidates remain independent.
- Do not add `run_attempt`, workflow YAML fetches, GitHub REST requests, Core state, or SwiftUI changes.
- Existing request budgets, last-known-good cache behavior, reset/generation guards, matrix-job detail behavior, and correlation semantics remain unchanged.
- Final implementation head must pass CI, Visual Regression, and CodeQL before merge.

---

### Task 1: Pure workflow-run supersession resolver

**Files:**
- Create: `Sources/SchneeBarGitHubActivityProvider/GitHubWorkflowRunSupersessionResolver.swift`
- Create: `Tests/SchneeBarGitHubActivityProviderTests/GitHubWorkflowRunSupersessionResolverTests.swift`

**Interfaces:**
- Consumes: `GitHubWorkflowRun.id`, `workflowID`, `event`, `runNumber`, `headSHA`, `pullRequestNumbers`, `updatedAt`.
- Produces:

```swift
public struct GitHubWorkflowRunSupersessionResolution: Equatable, Sendable {
    public let currentRuns: [GitHubWorkflowRun]
    public let supersededRunIDs: Set<Int64>
}

public struct GitHubWorkflowRunSupersessionResolver: Sendable {
    public init() {}
    public func resolve(runs: [GitHubWorkflowRun]) -> GitHubWorkflowRunSupersessionResolution
}
```

- [ ] **Step 1: Write RED resolver tests**

Create the test file with this helper:

```swift
import Foundation
import SchneeBarGitHub
import SchneeBarGitHubActivityProvider
import Testing

private func supersessionRun(
    id: Int64,
    workflowID: Int64 = 41,
    event: String = "pull_request",
    runNumber: Int,
    headSHA: String,
    pullRequests: [Int] = [120],
    updatedAt: TimeInterval,
    status: GitHubWorkflowRunStatus = .inProgress,
    conclusion: GitHubWorkflowRunConclusion? = nil
) throws -> GitHubWorkflowRun {
    GitHubWorkflowRun(
        id: id,
        workflowID: workflowID,
        name: "CI",
        displayTitle: "Build",
        event: event,
        status: status,
        conclusion: conclusion,
        runNumber: runNumber,
        headBranch: "feature",
        headSHA: headSHA,
        webURL: try #require(URL(string: "https://github.com/acme/app/actions/runs/\(id)")),
        pullRequestNumbers: pullRequests,
        createdAt: Date(timeIntervalSince1970: updatedAt - 10),
        updatedAt: Date(timeIntervalSince1970: updatedAt)
    )
}
```

Add these tests:

```swift
@Test
func supersedesOlderDifferentSHAInSamePullRequestLane() throws {
    let old = try supersessionRun(id: 80, runNumber: 80, headSHA: "AAA", updatedAt: 100)
    let current = try supersessionRun(id: 81, runNumber: 81, headSHA: "bbb", updatedAt: 200)

    let result = GitHubWorkflowRunSupersessionResolver().resolve(runs: [old, current])

    #expect(result.supersededRunIDs == Set([80]))
    #expect(result.currentRuns.map(\.id) == [81])
}

@Test
func newestCancelledRunStillSupersedesOlderDifferentSHA() throws {
    let old = try supersessionRun(id: 80, runNumber: 80, headSHA: "aaa", updatedAt: 100, status: .completed, conclusion: .failure)
    let current = try supersessionRun(id: 81, runNumber: 81, headSHA: "bbb", updatedAt: 200, status: .completed, conclusion: .cancelled)

    let result = GitHubWorkflowRunSupersessionResolver().resolve(runs: [old, current])

    #expect(result.supersededRunIDs == Set([80]))
    #expect(result.currentRuns.map(\.id) == [81])
}

@Test
func sameSHAKeepsBothRuns() throws {
    let old = try supersessionRun(id: 80, runNumber: 80, headSHA: "aaa", updatedAt: 100)
    let current = try supersessionRun(id: 81, runNumber: 81, headSHA: " AAA ", updatedAt: 200)

    let result = GitHubWorkflowRunSupersessionResolver().resolve(runs: [old, current])

    #expect(result.supersededRunIDs.isEmpty)
    #expect(result.currentRuns.map(\.id) == [81, 80])
}

@Test
func differentWorkflowIDsKeepBothRuns() throws {
    let first = try supersessionRun(id: 80, workflowID: 41, runNumber: 80, headSHA: "aaa", updatedAt: 100)
    let second = try supersessionRun(id: 81, workflowID: 42, runNumber: 81, headSHA: "bbb", updatedAt: 200)

    let result = GitHubWorkflowRunSupersessionResolver().resolve(runs: [first, second])

    #expect(result.supersededRunIDs.isEmpty)
    #expect(result.currentRuns.map(\.id) == [81, 80])
}

@Test
func differentEventsKeepBothRuns() throws {
    let first = try supersessionRun(id: 80, event: "pull_request", runNumber: 80, headSHA: "aaa", updatedAt: 100)
    let second = try supersessionRun(id: 81, event: "pull_request_target", runNumber: 81, headSHA: "bbb", updatedAt: 200)

    let result = GitHubWorkflowRunSupersessionResolver().resolve(runs: [first, second])

    #expect(result.supersededRunIDs.isEmpty)
    #expect(result.currentRuns.map(\.id) == [81, 80])
}

@Test
func differentPullRequestsKeepBothRuns() throws {
    let first = try supersessionRun(id: 80, runNumber: 80, headSHA: "aaa", pullRequests: [120], updatedAt: 100)
    let second = try supersessionRun(id: 81, runNumber: 81, headSHA: "bbb", pullRequests: [121], updatedAt: 200)

    let result = GitHubWorkflowRunSupersessionResolver().resolve(runs: [first, second])

    #expect(result.supersededRunIDs.isEmpty)
    #expect(result.currentRuns.map(\.id) == [81, 80])
}

@Test
func branchOnlyRunsKeepBothRuns() throws {
    let first = try supersessionRun(id: 80, event: "push", runNumber: 80, headSHA: "aaa", pullRequests: [], updatedAt: 100)
    let second = try supersessionRun(id: 81, event: "push", runNumber: 81, headSHA: "bbb", pullRequests: [], updatedAt: 200)

    let result = GitHubWorkflowRunSupersessionResolver().resolve(runs: [first, second])

    #expect(result.supersededRunIDs.isEmpty)
    #expect(result.currentRuns.map(\.id) == [81, 80])
}

@Test
func multiplePullRequestsKeepRuns() throws {
    let first = try supersessionRun(id: 80, runNumber: 80, headSHA: "aaa", pullRequests: [120, 121], updatedAt: 100)
    let second = try supersessionRun(id: 81, runNumber: 81, headSHA: "bbb", pullRequests: [120, 121], updatedAt: 200)

    let result = GitHubWorkflowRunSupersessionResolver().resolve(runs: [first, second])

    #expect(result.supersededRunIDs.isEmpty)
    #expect(result.currentRuns.map(\.id) == [81, 80])
}

@Test
func duplicateMaximumRunNumberKeepsEntireLane() throws {
    let old = try supersessionRun(id: 80, runNumber: 80, headSHA: "aaa", updatedAt: 100)
    let firstMax = try supersessionRun(id: 81, runNumber: 81, headSHA: "bbb", updatedAt: 190)
    let secondMax = try supersessionRun(id: 82, runNumber: 81, headSHA: "ccc", updatedAt: 200)

    let result = GitHubWorkflowRunSupersessionResolver().resolve(runs: [old, firstMax, secondMax])

    #expect(result.supersededRunIDs.isEmpty)
    #expect(result.currentRuns.map(\.id) == [82, 81, 80])
}

@Test
func emptyNormalizedNewestSHAKeepsLane() throws {
    let old = try supersessionRun(id: 80, runNumber: 80, headSHA: "aaa", updatedAt: 100)
    let current = try supersessionRun(id: 81, runNumber: 81, headSHA: "   ", updatedAt: 200)

    let result = GitHubWorkflowRunSupersessionResolver().resolve(runs: [old, current])

    #expect(result.supersededRunIDs.isEmpty)
    #expect(result.currentRuns.map(\.id) == [81, 80])
}

@Test
func emptyNormalizedOlderSHAIsNotSuppressed() throws {
    let old = try supersessionRun(id: 80, runNumber: 80, headSHA: "   ", updatedAt: 100)
    let current = try supersessionRun(id: 81, runNumber: 81, headSHA: "bbb", updatedAt: 200)

    let result = GitHubWorkflowRunSupersessionResolver().resolve(runs: [old, current])

    #expect(result.supersededRunIDs.isEmpty)
    #expect(result.currentRuns.map(\.id) == [81, 80])
}

@Test
func threeGenerationsKeepCurrentSHAFamily() throws {
    let oldest = try supersessionRun(id: 80, runNumber: 80, headSHA: "aaa", updatedAt: 100)
    let sameCurrentSHA = try supersessionRun(id: 81, runNumber: 81, headSHA: "bbb", updatedAt: 180)
    let current = try supersessionRun(id: 82, runNumber: 82, headSHA: "BBB", updatedAt: 200)

    let result = GitHubWorkflowRunSupersessionResolver().resolve(runs: [sameCurrentSHA, oldest, current])

    #expect(result.supersededRunIDs == Set([80]))
    #expect(result.currentRuns.map(\.id) == [82, 81])
}

@Test
func shuffledInputProducesSameResolution() throws {
    let old = try supersessionRun(id: 80, runNumber: 80, headSHA: "aaa", updatedAt: 100)
    let current = try supersessionRun(id: 81, runNumber: 81, headSHA: "bbb", updatedAt: 200)
    let unrelated = try supersessionRun(id: 90, workflowID: 99, runNumber: 3, headSHA: "zzz", pullRequests: [200], updatedAt: 150)
    let resolver = GitHubWorkflowRunSupersessionResolver()

    let first = resolver.resolve(runs: [old, current, unrelated])
    let second = resolver.resolve(runs: [unrelated, current, old])

    #expect(first == second)
    #expect(first.currentRuns.map(\.id) == [81, 90])
}
```

- [ ] **Step 2: Run the provider test target and verify RED**

```bash
tuist test SchneeBarGitHubActivityProviderTests -- -skipMacroValidation CODE_SIGNING_ALLOWED=NO
```

Expected: compile failure because the resolver types do not exist.

- [ ] **Step 3: Implement the resolver**

Create `GitHubWorkflowRunSupersessionResolver.swift`:

```swift
import Foundation
import SchneeBarGitHub

public struct GitHubWorkflowRunSupersessionResolution: Equatable, Sendable {
    public let currentRuns: [GitHubWorkflowRun]
    public let supersededRunIDs: Set<Int64>

    public init(currentRuns: [GitHubWorkflowRun], supersededRunIDs: Set<Int64>) {
        self.currentRuns = currentRuns
        self.supersededRunIDs = supersededRunIDs
    }
}

public struct GitHubWorkflowRunSupersessionResolver: Sendable {
    public init() {}

    public func resolve(runs: [GitHubWorkflowRun]) -> GitHubWorkflowRunSupersessionResolution {
        var runsByLane: [LaneKey: [GitHubWorkflowRun]] = [:]
        var supersededRunIDs = Set<Int64>()

        for run in runs {
            guard let pullRequestNumber = singlePullRequestNumber(run) else { continue }
            runsByLane[
                LaneKey(workflowID: run.workflowID, event: run.event, pullRequestNumber: pullRequestNumber),
                default: []
            ].append(run)
        }

        for laneRuns in runsByLane.values {
            guard let maximumRunNumber = laneRuns.map(\.runNumber).max() else { continue }
            let newestRuns = laneRuns.filter { $0.runNumber == maximumRunNumber }
            guard newestRuns.count == 1, let newest = newestRuns.first else { continue }

            let newestSHA = normalizedSHA(newest.headSHA)
            guard !newestSHA.isEmpty else { continue }

            for run in laneRuns where run.runNumber < maximumRunNumber {
                let headSHA = normalizedSHA(run.headSHA)
                guard !headSHA.isEmpty else { continue }
                if headSHA != newestSHA {
                    supersededRunIDs.insert(run.id)
                }
            }
        }

        return GitHubWorkflowRunSupersessionResolution(
            currentRuns: runs
                .filter { !supersededRunIDs.contains($0.id) }
                .sorted(by: runPrecedes),
            supersededRunIDs: supersededRunIDs
        )
    }

    private func singlePullRequestNumber(_ run: GitHubWorkflowRun) -> Int? {
        let numbers = Set(run.pullRequestNumbers.filter { $0 > 0 })
        guard numbers.count == 1 else { return nil }
        return numbers.first
    }

    private func normalizedSHA(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private func runPrecedes(_ lhs: GitHubWorkflowRun, _ rhs: GitHubWorkflowRun) -> Bool {
        if lhs.updatedAt != rhs.updatedAt { return lhs.updatedAt > rhs.updatedAt }
        if lhs.runNumber != rhs.runNumber { return lhs.runNumber > rhs.runNumber }
        return lhs.id > rhs.id
    }
}

private struct LaneKey: Hashable {
    let workflowID: Int64
    let event: String
    let pullRequestNumber: Int
}
```

- [ ] **Step 4: Run the provider test target and verify GREEN**

```bash
tuist test SchneeBarGitHubActivityProviderTests -- -skipMacroValidation CODE_SIGNING_ALLOWED=NO
```

Expected: all resolver tests and existing provider tests pass.

- [ ] **Step 5: Commit Task 1**

```bash
git add Sources/SchneeBarGitHubActivityProvider/GitHubWorkflowRunSupersessionResolver.swift Tests/SchneeBarGitHubActivityProviderTests/GitHubWorkflowRunSupersessionResolverTests.swift
git commit -m "feat: resolve superseded GitHub workflow runs"
```

---

### Task 2: Normalize Workflow activity and evidence before caching

**Files:**
- Modify: `Sources/SchneeBarGitHubActivityProvider/GitHubActivityProvider.swift`
- Modify: `Tests/SchneeBarGitHubActivityProviderTests/GitHubActivityProviderTests.swift`

**Interfaces:**
- Consumes: `GitHubWorkflowRunSupersessionResolver.resolve(runs:)` from Task 1.
- Produces: Workflow activities and Workflow evidence derived only from `resolution.currentRuns`.

- [ ] **Step 1: Generalize the provider-test Workflow helper**

Change `workflowRun(...)` to add defaulted `workflowID`, `event`, `runNumber`, `headBranch`, `headSHA`, and `pullRequestNumbers` parameters while preserving all current defaults.

- [ ] **Step 2: Add RED stale-activity tests**

Add `suppressesSupersededPullRequestWorkflowActivity` with old run #80 / SHA `aaa` / failure and current run #81 / SHA `bbb` / running in the same `pull_request` PR #120 lane. Assert only `github-actions:1:81` remains and its state is `.running`.

Add `successfulReplacementCanLeaveWorkflowInboxEmpty` with old failure #80 / `aaa` and current success #81 / `bbb`; assert `result.surface(.workflows).items.isEmpty`.

- [ ] **Step 3: Run provider tests and verify RED**

```bash
tuist test SchneeBarGitHubActivityProviderTests -- -skipMacroValidation CODE_SIGNING_ALLOWED=NO
```

Expected: the two new tests fail because raw runs still feed mapping/evidence.

- [ ] **Step 4: Inject/default the resolver and normalize once**

Add:

```swift
private let workflowRunSupersessionResolver: GitHubWorkflowRunSupersessionResolver
```

and initializer parameter:

```swift
workflowRunSupersessionResolver: GitHubWorkflowRunSupersessionResolver = GitHubWorkflowRunSupersessionResolver(),
```

Inside `loadWorkflowRepositories`, capture `let resolver = workflowRunSupersessionResolver`, then immediately after `workflowRuns(...)` returns:

```swift
let currentRuns = resolver.resolve(runs: runs).currentRuns
let activities = mapper.visibleActivities(runs: currentRuns, repository: repository)
let visibleRunIDs = Set(activities.map(\.workflowRunID))
let evidence = currentRuns.compactMap { run -> GitHubWorkflowEvidence? in
    let headSHA = run.headSHA.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    guard !headSHA.isEmpty else { return nil }
    return GitHubWorkflowEvidence(
        repositoryID: repository.id,
        headSHA: headSHA,
        classification: mapper.classification(for: run),
        updatedAt: run.updatedAt,
        isVisible: visibleRunIDs.contains(run.id)
    )
}
```

Do not store `supersededRunIDs` in actor state.

- [ ] **Step 5: Run provider tests and verify GREEN**

```bash
tuist test SchneeBarGitHubActivityProviderTests -- -skipMacroValidation CODE_SIGNING_ALLOWED=NO
```

- [ ] **Step 6: Commit Task 2**

```bash
git add Sources/SchneeBarGitHubActivityProvider/GitHubActivityProvider.swift Tests/SchneeBarGitHubActivityProviderTests/GitHubActivityProviderTests.swift
git commit -m "feat: suppress superseded workflow activity"
```

---

### Task 3: Lock Check-candidate and cache semantics

**Files:**
- Modify: `Tests/SchneeBarGitHubActivityProviderTests/GitHubActivityProviderMultiSourceTests.swift`
- Modify: `Tests/SchneeBarGitHubActivityProviderTests/GitHubActivityProviderCacheTests.swift`
- Verify unchanged: `Tests/SchneeBarGitHubActivityProviderTests/GitHubActivityProviderBudgetTests.swift`
- Modify: `docs/DEVELOPMENT_PLAN.md`

**Interfaces:**
- Consumes: Task 2 provider normalization.
- Produces: regression proof that Workflow supersession removes only Workflow evidence while preserving Review evidence, last-known-good cache behavior, and request budgets.

- [ ] **Step 1: Generalize `multiSourceWorkflowRun` and make `MultiSourceCheckRequest` Hashable**

Add defaulted `workflowID`, `event`, `runNumber`, `pullRequestNumbers`, and `updatedAt` parameters to `multiSourceWorkflowRun`. Change:

```swift
private struct MultiSourceCheckRequest: Equatable, Hashable, Sendable {
    let repositoryID: Int64
    let headSHA: String
}
```

- [ ] **Step 2: Add Workflow-derived Check evidence regression**

Using `MultiSourceWorkflowLoader`, `MultiSourceReviewLoader`, and `MultiSourceCheckLoader`, load old failure #80 / SHA `aaa` and current success #81 / SHA `bbb` in the same PR lane. With no review requests, assert:

```swift
#expect(await checkLoader.requestedChecks() == [
    MultiSourceCheckRequest(repositoryID: 1, headSHA: currentSHA),
])
```

- [ ] **Step 3: Add Review-derived candidate independence regression**

Return a direct `GitHubReviewRequest` for PR #120 with `headSHA: oldSHA`, while Workflow supersession selects `currentSHA`. Set `maximumCheckTargetsPerRepository: 2` and assert:

```swift
#expect(Set(await checkLoader.requestedChecks()) == Set([
    MultiSourceCheckRequest(repositoryID: 1, headSHA: oldSHA),
    MultiSourceCheckRequest(repositoryID: 1, headSHA: currentSHA),
]))
```

- [ ] **Step 4: Make the cache Workflow loader sequence-capable**

Add:

```swift
private enum CacheWorkflowStep: Sendable {
    case success([GitHubWorkflowRun])
    case httpStatus(Int)
}
```

Change `CacheWorkflowLoader` to store `[CacheWorkflowStep]`, retain `init(runs:)` as `steps = [.success(runs)]`, add `init(steps:)`, advance an index per request, and throw `GitHubActionsClientError.httpStatus(status)` for `.httpStatus`.

- [ ] **Step 5: Add successful-refresh cache replacement regression**

Generalize `cacheWorkflowRun` with defaulted `id`, `event`, `runNumber`, `pullRequestNumbers`, `status`, `conclusion`, and `updatedAt`. Configure Workflow steps as `.success([old])` then `.success([old, current])`. Assert first Workflow items contain run 80 and second Workflow items contain only run 81.

- [ ] **Step 6: Add failed-refresh last-known-good regression**

Configure `.success([current])` then `.httpStatus(503)`. Assert the failed refresh still contains run 81 and reports the repository's existing Workflow failure classification. Before writing the assertion, read `GitHubActivityProvider.failureReason(for:)` and assert its existing mapping for HTTP 503; do not change that mapping in this feature.

- [ ] **Step 7: Run provider tests including existing budget tests**

```bash
tuist test SchneeBarGitHubActivityProviderTests -- -skipMacroValidation CODE_SIGNING_ALLOWED=NO
```

Expected: supersession, multi-source, cache, bounded-concurrency, polling-budget, polling-rotation, and reset/generation tests all pass.

- [ ] **Step 8: Run full CI-equivalent build/test before docs completion**

```bash
tuist generate
tuist build -- -skipMacroValidation CODE_SIGNING_ALLOWED=NO
tuist test -- -skipMacroValidation CODE_SIGNING_ALLOWED=NO
```

- [ ] **Step 9: Update the roadmap**

In `docs/DEVELOPMENT_PLAN.md`, move PR-scoped conservative superseded-run handling into the implemented Phase 3 foundation, remove it from the next-work list, and retain branch/push supersession plus re-run-attempt UX as deferred work.

- [ ] **Step 10: Commit Task 3**

```bash
git add Tests/SchneeBarGitHubActivityProviderTests/GitHubActivityProviderMultiSourceTests.swift Tests/SchneeBarGitHubActivityProviderTests/GitHubActivityProviderCacheTests.swift docs/DEVELOPMENT_PLAN.md
git commit -m "test: harden superseded workflow handling"
```

---

### Task 4: PR review and exact-head release gates

**Files:**
- No production file changes expected.
- Update PR body/status only after evidence exists.

**Interfaces:**
- Consumes: completed Tasks 1-3.
- Produces: reviewed feature branch ready for integration.

- [ ] **Step 1: Open a Draft PR from the feature branch to `main` before implementation if one does not already exist**

Title:

```text
feat: suppress superseded GitHub workflow runs
```

Summary:

```text
- suppress only older different-SHA runs in the same workflow/event/single-PR lane
- keep same-SHA, branch-only, ambiguous-PR, and cross-event/workflow runs
- remove superseded runs before both Workflow activity and Workflow-derived Check evidence
- add no REST request, YAML fetch, Core state, or UI surface
```

- [ ] **Step 2: Self-review the final diff**

Verify:

```text
[ ] no GitHubActionsClient / REST endpoint changes
[ ] no ActivityItem / Core / SwiftUI changes
[ ] resolver lane key is workflowID + event + one positive PR number
[ ] duplicate max runNumber performs no suppression
[ ] same-SHA older runs remain
[ ] provider feeds currentRuns to both mapper and evidence
[ ] Review-derived Check candidate behavior remains intact
[ ] request-budget constants are untouched
[ ] reset/generation logic is untouched
```

- [ ] **Step 3: Verify exact-head CI and Visual Regression**

On the final implementation SHA require:

```text
CI                 -> success
Visual Regression  -> success
```

No new Visual baseline is expected.

- [ ] **Step 4: Mark Ready and verify CodeQL on that same SHA**

Require:

```text
CodeQL Build for analysis -> success
CodeQL Analyze            -> success
```

- [ ] **Step 5: Verify final PR state**

Require:

```text
PR mergeable = true
unresolved review threads = 0
head SHA equals the SHA that passed CI / Visual Regression / CodeQL
```

- [ ] **Step 6: Integrate only with the verified SHA**

When merge is authorized, squash merge using `expected_head_sha` set to the verified exact head SHA, then confirm `main` points to the returned merge SHA.

# GitHub Superseded Run Handling Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Remove proven-obsolete pull-request workflow runs from Developer Activity and Workflow-derived Check evidence without suppressing ambiguous, branch-only, or same-SHA runs.

**Architecture:** Add one pure `GitHubWorkflowRunSupersessionResolver` inside `SchneeBarGitHubActivityProvider`. `GitHubActivityProvider.loadWorkflowRepositories` invokes it exactly once after a successful Workflow API load and feeds only `currentRuns` to both `GitHubWorkflowActivityMapper` and `GitHubWorkflowEvidence`, preserving all existing cache, request-budget, generation, and UI behavior.

**Tech Stack:** Swift 6.3, Swift Testing, Swift Concurrency, Tuist 4.203.1, Xcode 26.6, GitHub Actions on `macos-26`.

**Spec:** `docs/superpowers/specs/2026-09-18-github-superseded-run-handling-design.md`

## Global Constraints

- Supersession lane is exactly `(workflowID, event, single positive pullRequestNumber)` and is repository-scoped by invocation.
- Only a strictly lower `runNumber` with a different non-empty normalized `headSHA` may be superseded.
- Same-SHA runs are retained even when their `runNumber` is older.
- Zero/multiple PR-number runs, duplicate maximum `runNumber` lanes, empty normalized SHAs, different workflow IDs, different events, and branch-only runs are retained.
- A newest cancelled/skipped run still supersedes an obsolete different-SHA run.
- Superseded runs must feed neither Workflow Inbox activity nor Workflow-derived Check evidence.
- Review-derived Check candidates remain independent.
- Do not add `run_attempt`, workflow YAML fetches, GitHub REST requests, Core state, or SwiftUI changes.
- Existing workflow request budgets, last-known-good cache behavior, reset/generation guards, matrix-job detail behavior, and correlation semantics remain unchanged.
- Final implementation head must pass CI, Visual Regression, and CodeQL before merge.

---

### Task 1: Pure workflow-run supersession resolver

**Files:**
- Create: `Sources/SchneeBarGitHubActivityProvider/GitHubWorkflowRunSupersessionResolver.swift`
- Create: `Tests/SchneeBarGitHubActivityProviderTests/GitHubWorkflowRunSupersessionResolverTests.swift`

**Interfaces:**
- Consumes: existing `GitHubWorkflowRun` fields `id`, `workflowID`, `event`, `runNumber`, `headSHA`, `pullRequestNumbers`, `updatedAt`.
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

- [ ] **Step 1: Add RED tests for positive supersession cases**

Create `GitHubWorkflowRunSupersessionResolverTests.swift` with focused helpers and these tests:

```swift
import Foundation
import SchneeBarGitHub
import SchneeBarGitHubActivityProvider
import Testing

@Test
func supersedesOlderDifferentSHAInSamePullRequestLane() throws {
    let old = try supersessionRun(
        id: 80,
        workflowID: 41,
        event: "pull_request",
        runNumber: 80,
        headSHA: "AAA",
        pullRequests: [120],
        updatedAt: 100
    )
    let current = try supersessionRun(
        id: 81,
        workflowID: 41,
        event: "pull_request",
        runNumber: 81,
        headSHA: "bbb",
        pullRequests: [120],
        updatedAt: 200
    )

    let resolution = GitHubWorkflowRunSupersessionResolver().resolve(runs: [old, current])

    #expect(resolution.supersededRunIDs == Set([80]))
    #expect(resolution.currentRuns.map(\.id) == [81])
}

@Test
func newestCancelledRunStillSupersedesOlderDifferentSHA() throws {
    let old = try supersessionRun(id: 80, workflowID: 41, event: "pull_request", runNumber: 80, headSHA: "aaa", pullRequests: [120], updatedAt: 100)
    let current = try supersessionRun(id: 81, workflowID: 41, event: "pull_request", runNumber: 81, headSHA: "bbb", pullRequests: [120], updatedAt: 200, status: .completed, conclusion: .cancelled)

    let resolution = GitHubWorkflowRunSupersessionResolver().resolve(runs: [old, current])

    #expect(resolution.supersededRunIDs == Set([80]))
    #expect(resolution.currentRuns.map(\.id) == [81])
}

@Test
func threeGenerationsKeepCurrentSHAFamily() throws {
    let oldest = try supersessionRun(id: 80, workflowID: 41, event: "pull_request", runNumber: 80, headSHA: "aaa", pullRequests: [120], updatedAt: 100)
    let sameCurrentSHA = try supersessionRun(id: 81, workflowID: 41, event: "pull_request", runNumber: 81, headSHA: "bbb", pullRequests: [120], updatedAt: 180)
    let current = try supersessionRun(id: 82, workflowID: 41, event: "pull_request", runNumber: 82, headSHA: "BBB", pullRequests: [120], updatedAt: 200)

    let resolution = GitHubWorkflowRunSupersessionResolver().resolve(runs: [sameCurrentSHA, oldest, current])

    #expect(resolution.supersededRunIDs == Set([80]))
    #expect(resolution.currentRuns.map(\.id) == [82, 81])
}
```

Use this deterministic helper in the same test file:

```swift
private func supersessionRun(
    id: Int64,
    workflowID: Int64,
    event: String,
    runNumber: Int,
    headSHA: String,
    pullRequests: [Int],
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

- [ ] **Step 2: Run the new resolver test target and verify RED**

Run:

```bash
tuist test SchneeBarGitHubActivityProviderTests -- -skipMacroValidation CODE_SIGNING_ALLOWED=NO
```

Expected: compile failure because `GitHubWorkflowRunSupersessionResolver` and `GitHubWorkflowRunSupersessionResolution` do not exist.

- [ ] **Step 3: Add RED ambiguity/safety tests before implementation**

Add explicit tests proving no suppression for:

```swift
@Test func sameSHAKeepsBothRuns() throws { /* run 80 aaa + run 81 AAA => IDs [81, 80], superseded empty */ }
@Test func differentWorkflowIDsKeepBothRuns() throws { /* workflow 41 vs 42 */ }
@Test func differentEventsKeepBothRuns() throws { /* pull_request vs pull_request_target */ }
@Test func differentPullRequestsKeepBothRuns() throws { /* PR 120 vs 121 */ }
@Test func branchOnlyRunsKeepBothRuns() throws { /* [] + [] */ }
@Test func multiplePullRequestsKeepRuns() throws { /* [120, 121] */ }
@Test func duplicateMaximumRunNumberKeepsEntireLane() throws { /* two run #81 entries */ }
@Test func emptyNormalizedSHAKeepsAffectedLane() throws { /* newest SHA whitespace */ }
@Test func shuffledInputProducesSameResolution() throws { /* compare two permutations */ }
```

For deterministic ordering, assert retained IDs sort by `updatedAt` descending, then `runNumber` descending, then `id` descending.

- [ ] **Step 4: Implement the minimal resolver**

Create `GitHubWorkflowRunSupersessionResolver.swift`:

```swift
import Foundation
import SchneeBarGitHub

public struct GitHubWorkflowRunSupersessionResolution: Equatable, Sendable {
    public let currentRuns: [GitHubWorkflowRun]
    public let supersededRunIDs: Set<Int64>

    public init(
        currentRuns: [GitHubWorkflowRun],
        supersededRunIDs: Set<Int64>
    ) {
        self.currentRuns = currentRuns
        self.supersededRunIDs = supersededRunIDs
    }
}

public struct GitHubWorkflowRunSupersessionResolver: Sendable {
    public init() {}

    public func resolve(
        runs: [GitHubWorkflowRun]
    ) -> GitHubWorkflowRunSupersessionResolution {
        var runsByLane: [LaneKey: [GitHubWorkflowRun]] = [:]
        var supersededRunIDs = Set<Int64>()

        for run in runs {
            guard let pullRequestNumber = singlePullRequestNumber(run) else { continue }
            let key = LaneKey(
                workflowID: run.workflowID,
                event: run.event,
                pullRequestNumber: pullRequestNumber
            )
            runsByLane[key, default: []].append(run)
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

        let currentRuns = runs
            .filter { !supersededRunIDs.contains($0.id) }
            .sorted(by: runPrecedes)

        return GitHubWorkflowRunSupersessionResolution(
            currentRuns: currentRuns,
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

- [ ] **Step 5: Run resolver tests and verify GREEN**

Run:

```bash
tuist test SchneeBarGitHubActivityProviderTests -- -skipMacroValidation CODE_SIGNING_ALLOWED=NO
```

Expected: resolver tests pass; existing provider tests remain green.

- [ ] **Step 6: Commit Task 1**

```bash
git add Sources/SchneeBarGitHubActivityProvider/GitHubWorkflowRunSupersessionResolver.swift \
        Tests/SchneeBarGitHubActivityProviderTests/GitHubWorkflowRunSupersessionResolverTests.swift
git commit -m "feat: resolve superseded GitHub workflow runs"
```

---

### Task 2: Normalize Workflow activity and evidence before caching

**Files:**
- Modify: `Sources/SchneeBarGitHubActivityProvider/GitHubActivityProvider.swift`
- Modify: `Tests/SchneeBarGitHubActivityProviderTests/GitHubActivityProviderTests.swift`

**Interfaces:**
- Consumes: `GitHubWorkflowRunSupersessionResolver.resolve(runs:)` from Task 1.
- Produces: Workflow load outcomes whose `activities` and `evidence` are derived only from `resolution.currentRuns`.

- [ ] **Step 1: Generalize the existing provider-test Workflow helper**

Change the existing private helper at the bottom of `GitHubActivityProviderTests.swift` from fixed `workflowID/event/runNumber/headSHA/pullRequestNumbers` values to defaulted parameters:

```swift
private func workflowRun(
    id: Int64,
    repository: GitHubRepositoryAccess,
    status: GitHubWorkflowRunStatus,
    conclusion: GitHubWorkflowRunConclusion?,
    updatedAt: TimeInterval,
    workflowID: Int64 = 10,
    event: String = "push",
    runNumber: Int = 1,
    headBranch: String? = "main",
    headSHA: String = "abcdef",
    pullRequestNumbers: [Int] = []
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
        headBranch: headBranch,
        headSHA: headSHA,
        webURL: try #require(URL(string: "\(repository.webURL.absoluteString)/actions/runs/\(id)")),
        pullRequestNumbers: pullRequestNumbers,
        createdAt: Date(timeIntervalSince1970: updatedAt - 10),
        updatedAt: Date(timeIntervalSince1970: updatedAt)
    )
}
```

Existing tests continue calling it unchanged because every new parameter has the current behavior as its default.

- [ ] **Step 2: Add RED provider test for stale Inbox activity removal**

Add:

```swift
@Test
func suppressesSupersededPullRequestWorkflowActivity() async throws {
    let repo = try repository(id: 1, fullName: "acme/api")
    let loader = ActivityLoaderStub(responses: [
        1: .success([
            try workflowRun(
                id: 80,
                repository: repo,
                status: .completed,
                conclusion: .failure,
                updatedAt: 100,
                event: "pull_request",
                runNumber: 80,
                headSHA: "aaa",
                pullRequestNumbers: [120]
            ),
            try workflowRun(
                id: 81,
                repository: repo,
                status: .inProgress,
                conclusion: nil,
                updatedAt: 200,
                event: "pull_request",
                runNumber: 81,
                headSHA: "bbb",
                pullRequestNumbers: [120]
            ),
        ]),
    ])
    let provider = GitHubActivityProvider(workflowRunLoader: loader)
    let profile = try githubProfile(selection: .allAccessible)
    let inventory = try githubInventory(repositories: [repo])

    let result = await provider.load(profile: profile, inventory: inventory)

    #expect(result.items.map(\.id) == ["github-actions:1:81"])
    #expect(result.items.map(\.state) == [.running])
}
```

- [ ] **Step 3: Add RED provider test for hidden successful current generation**

Add a lane containing old SHA `aaa` failure and new SHA `bbb` success. Assert no Workflow Inbox item remains after load:

```swift
#expect(result.surface(.workflows).items.isEmpty)
```

This proves old failure suppression is independent of whether the replacement is itself visible.

- [ ] **Step 4: Run provider tests and verify RED**

Run:

```bash
tuist test SchneeBarGitHubActivityProviderTests -- -skipMacroValidation CODE_SIGNING_ALLOWED=NO
```

Expected: the new provider tests fail because `GitHubActivityProvider` still maps the raw `runs` array directly.

- [ ] **Step 5: Inject/default the resolver and normalize exactly once**

In `GitHubActivityProvider` add:

```swift
private let workflowRunSupersessionResolver: GitHubWorkflowRunSupersessionResolver
```

Extend the initializer with:

```swift
workflowRunSupersessionResolver: GitHubWorkflowRunSupersessionResolver = GitHubWorkflowRunSupersessionResolver(),
```

and assign it.

Inside `loadWorkflowRepositories`, capture the resolver alongside existing immutable dependencies:

```swift
let resolver = workflowRunSupersessionResolver
```

Immediately after `loader.workflowRuns(...)` returns, replace raw mapping with:

```swift
let resolution = resolver.resolve(runs: runs)
let currentRuns = resolution.currentRuns
let activities = mapper.visibleActivities(
    runs: currentRuns,
    repository: repository
)
let visibleRunIDs = Set(activities.map(\.workflowRunID))
let evidence = currentRuns.compactMap { run -> GitHubWorkflowEvidence? in
    let headSHA = run.headSHA
        .trimmingCharacters(in: .whitespacesAndNewlines)
        .lowercased()
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

Do not store `supersededRunIDs` in provider state.

- [ ] **Step 6: Run provider tests and verify GREEN**

Run:

```bash
tuist test SchneeBarGitHubActivityProviderTests -- -skipMacroValidation CODE_SIGNING_ALLOWED=NO
```

Expected: new supersession tests and all existing provider tests pass.

- [ ] **Step 7: Commit Task 2**

```bash
git add Sources/SchneeBarGitHubActivityProvider/GitHubActivityProvider.swift \
        Tests/SchneeBarGitHubActivityProviderTests/GitHubActivityProviderTests.swift
git commit -m "feat: suppress superseded workflow activity"
```

---

### Task 3: Lock Check-candidate, cache, and request-budget regressions

**Files:**
- Modify: `Tests/SchneeBarGitHubActivityProviderTests/GitHubActivityProviderTests.swift`
- Modify: `docs/DEVELOPMENT_PLAN.md`

**Interfaces:**
- Consumes: Task 2 provider normalization.
- Produces: regression proof that supersession changes only successful Workflow normalization and does not alter Review candidates, failure cache semantics, reset/generation logic, or network budgets.

- [ ] **Step 1: Add provider regression for Workflow-derived Check evidence**

Use the existing Review/Check loader stubs in `GitHubActivityProviderTests.swift` to create one monitored repository with:

```text
old Workflow: run #80 / PR #120 / SHA aaa / failed
new Workflow: run #81 / PR #120 / SHA bbb / success
Review requests: []
Checks: record requested SHAs
```

Configure `maximumCheckTargetsPerRefresh: 4` and `maximumCheckTargetsPerRepository: 2`, load once, then assert:

```swift
#expect(await checkLoader.requestedHeadSHAs() == ["bbb"])
```

The assertion must prove `aaa` was removed from Workflow evidence before `GitHubCheckCandidatePlanner` ran.

- [ ] **Step 2: Add regression proving Review-derived candidates remain independent**

Return a direct Review Request for current review head `aaa` while Workflow supersession selects `bbb`. Assert both candidate SHAs can be requested within the per-repository budget:

```swift
#expect(Set(await checkLoader.requestedHeadSHAs()) == Set(["aaa", "bbb"]))
```

This locks the spec rule that supersession removes only obsolete Workflow evidence, not evidence from another source.

- [ ] **Step 3: Add successful-refresh cache replacement regression**

Use a sequence-capable Workflow loader for the same repository:

```text
load 1 -> old run #80 / SHA aaa / failed only
load 2 -> old run #80 / SHA aaa / failed + new run #81 / SHA bbb / running
```

Call `provider.load` twice and assert the second result contains only run 81 Workflow activity. The test must not manually reset the provider between loads.

- [ ] **Step 4: Keep failure-cache behavior explicit**

Extend or reuse the existing failure/cache test so this sequence is covered:

```text
load 1 -> successful current activity
load 2 -> Workflow loader HTTP failure
```

Assert load 2 still exposes the load-1 cached Workflow item and reports the Workflow surface failure. Do not change production code for this test unless it reveals a regression caused by Tasks 1-2.

- [ ] **Step 5: Run provider tests**

Run:

```bash
tuist test SchneeBarGitHubActivityProviderTests -- -skipMacroValidation CODE_SIGNING_ALLOWED=NO
```

Expected: all supersession, cache, Check candidate, bounded concurrency, polling rotation, and generation-reset tests pass.

- [ ] **Step 6: Run the full test suite before documenting completion**

Run exactly the CI commands:

```bash
tuist generate
tuist build -- -skipMacroValidation CODE_SIGNING_ALLOWED=NO
tuist test -- -skipMacroValidation CODE_SIGNING_ALLOWED=NO
```

Expected: all commands exit 0.

- [ ] **Step 7: Update Phase 3 roadmap**

In `docs/DEVELOPMENT_PLAN.md`:

- move superseded-run handling from the Phase 3 next-work list into the implemented foundation;
- state that supersession is PR-scoped and conservative;
- keep branch/push supersession and re-run-attempt UX deferred;
- leave the next remaining Phase 3 priorities unchanged except for removing this completed item.

- [ ] **Step 8: Commit Task 3**

```bash
git add Tests/SchneeBarGitHubActivityProviderTests/GitHubActivityProviderTests.swift \
        docs/DEVELOPMENT_PLAN.md
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

Use title:

```text
feat: suppress superseded GitHub workflow runs
```

PR summary must state:

```text
- suppress only older different-SHA runs in the same workflow/event/single-PR lane
- keep same-SHA, branch-only, ambiguous-PR, and cross-event/workflow runs
- remove superseded runs before both Workflow activity and Workflow-derived Check evidence
- add no REST request, YAML fetch, Core state, or UI surface
```

- [ ] **Step 2: Self-review the final diff**

Verify all of the following directly from the PR patch:

```text
[ ] no GitHubActionsClient / REST endpoint changes
[ ] no ActivityItem / Core / SwiftUI changes
[ ] resolver lane key is workflowID + event + one positive PR number
[ ] duplicate max runNumber performs no suppression
[ ] same-SHA older runs remain
[ ] provider feeds currentRuns to both mapper and evidence
[ ] Review-derived Check candidate code is untouched
[ ] request-budget constants are untouched
[ ] reset/generation/cache failure logic is untouched except test coverage
```

Any discrepancy is a blocking review finding and must be fixed before Ready-for-review.

- [ ] **Step 3: Run fresh exact-head CI and Visual Regression**

Push the final implementation head and wait for these PR workflows on that exact SHA:

```text
CI                 -> success
Visual Regression  -> success
```

Visual Regression must use the existing scenes; no new baseline should be required.

- [ ] **Step 4: Mark the PR Ready for review and run CodeQL on the same SHA**

Do not add commits after Ready unless fixing a verified issue. Confirm:

```text
CodeQL Build for analysis -> success
CodeQL Analyze            -> success
```

- [ ] **Step 5: Confirm PR review state**

On the exact final SHA verify:

```text
PR mergeable = true
unresolved review threads = 0
head SHA equals the SHA that passed CI / Visual Regression / CodeQL
```

- [ ] **Step 6: Integration**

Only after the exact-head gates above are all green, follow the repository's established integration choice. When authorized to merge, use squash merge with `expected_head_sha` set to the verified exact head SHA, then confirm `main` points to the returned merge SHA.

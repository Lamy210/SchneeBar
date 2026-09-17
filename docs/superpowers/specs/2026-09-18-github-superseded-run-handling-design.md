# GitHub Superseded Run Handling Design

**Date:** 2026-09-18  
**Status:** Approved after self-review  
**Scope:** Phase 3 Developer Activity hardening

## Goal

Prevent stale GitHub Actions workflow failures and in-progress states from remaining in SchneeBar's Developer Activity Inbox after a pull request has advanced to a newer commit and the same workflow has started a newer run for that PR.

The feature must be conservative. SchneeBar should suppress an older workflow run only when GitHub data provides strong evidence that the run belongs to the same pull-request workflow lane and a newer run represents a different PR head generation.

## API Reality

GitHub distinguishes a new workflow run from a re-run attempt:

- `run_number` increments for a new run of a workflow;
- `run_number` does not change when the same workflow run is re-run;
- `run_attempt` begins at 1 and increments for each re-run attempt;
- re-run endpoints operate on the existing workflow run ID.

SchneeBar therefore does **not** use `run_attempt` for supersession in this change. Existing `GitHubWorkflowRun` identity remains the GitHub run ID. The existing latest-attempt Workflow Jobs behavior remains unchanged.

## Non-goals

This change does **not**:

- suppress branch-only or push-only runs;
- infer GitHub Actions `concurrency` groups;
- fetch workflow YAML;
- add new GitHub REST requests;
- add `run_attempt` to `GitHubWorkflowRun`;
- suppress multiple runs for the same head SHA;
- alter GitHub re-run behavior;
- change `GitHubWorkflowExecutionCorrelator` semantics;
- add historical/superseded rows to the UI;
- add a new Core `ActivityItem` state;
- persist supersession decisions across launches independently of the existing activity cache.

## Existing Architecture

Workflow polling currently follows this shape:

```text
GitHubWorkflowRunService
        |
        v
[GitHubWorkflowRun]
        |
        +--> GitHubWorkflowActivityMapper --> visible Workflow activity
        |
        +--> GitHubWorkflowEvidence --------> Check candidate discovery
        |
        v
GitHubActivityProvider caches / source result
        |
        v
Developer Activity Inbox
```

`GitHubWorkflowRun` already carries the fields needed for conservative supersession: `id`, `workflowID`, `event`, `runNumber`, `headSHA`, `pullRequestNumbers`, timestamps, status, and conclusion.

`GitHubWorkflowExecutionCorrelator` already treats shared pull-request identity and shared head SHA as stronger evidence than branch names or timestamps. Supersession should preserve that safety posture rather than introduce branch/time heuristics.

## Design Decision

Add a GitHub-specific `GitHubWorkflowRunSupersessionResolver` in `SchneeBarGitHubActivityProvider`.

The resolver runs immediately after a repository's workflow runs are successfully loaded and before both activity mapping and workflow-evidence creation.

```text
[GitHubWorkflowRun]
        |
        v
GitHubWorkflowRunSupersessionResolver
      /        \
 current      superseded
   |              |
   |              +--> discarded from Inbox and Check evidence
   |
   +--> Activity mapper
   +--> Workflow evidence
```

The resolver is presentation/polling normalization only. It does not mutate GitHub models and does not write persistent state.

## Supersession Lane

A run is eligible for supersession analysis only when its normalized pull-request number set contains **exactly one** positive PR number.

For eligible runs, the lane key is exactly:

```text
(workflowID, event, pullRequestNumber)
```

Repository identity is implicit because the resolver is invoked per repository load.

The key intentionally excludes branch name, display title, timestamps, and workflow name.

### Why these fields

- `workflowID` identifies the actual GitHub workflow rather than relying on mutable names;
- `event` prevents different trigger semantics from being collapsed together;
- a single PR number provides strong user-facing lineage evidence;
- repository scoping prevents cross-repository grouping by construction.

## Current Generation Selection

Within each eligible lane:

1. find the maximum `runNumber`;
2. the run with that `runNumber` is the lane's current run;
3. normalize its `headSHA` by trimming whitespace and lowercasing;
4. if that SHA is empty, perform no suppression for the lane;
5. any older run with a **different non-empty head SHA** is superseded;
6. any older run with the **same head SHA** remains current-visible data and is not suppressed.

The GitHub model validates `runNumber > 0` and non-empty `headSHA`, but the resolver still treats malformed/empty normalized values conservatively if tests construct such values directly.

If duplicate maximum `runNumber` values somehow appear in one lane, the resolver performs no suppression for that lane rather than inventing a tie-break rule.

## Examples

### Old failure replaced by a newer PR head

```text
Workflow 41 / pull_request / PR #120
Run #80 · SHA aaa · failed
Run #81 · SHA bbb · running
```

Result:

```text
Run #80 -> superseded
Run #81 -> current
```

Only Run #81 may create Workflow activity/evidence.

### Newest run succeeds

```text
Run #80 · SHA aaa · failed
Run #81 · SHA bbb · success
```

Run #80 is suppressed. Run #81 remains available to workflow evidence, but normal Workflow activity visibility rules may hide the successful activity.

### Newest run is cancelled or skipped

```text
Run #80 · SHA aaa · failed
Run #81 · SHA bbb · cancelled
```

Run #80 is still superseded because the PR head generation advanced from `aaa` to `bbb`. Run #81 may itself be ignored by the existing activity mapper. The Inbox may therefore show no Workflow item for that lane, which is preferable to showing a stale failure for an obsolete commit.

### Same SHA is not supersession

```text
Run #80 · SHA aaa · failed
Run #81 · SHA aaa · running
```

Both runs remain. SchneeBar does not infer that one same-commit run replaces another because GitHub can legitimately produce multiple runs for one commit.

### Ambiguous or missing PR evidence

```text
Run A pullRequestNumbers = []
Run B pullRequestNumbers = [120, 121]
```

Neither participates in supersession analysis.

## Public Resolver Contract

The resolver is GitHub-provider infrastructure rather than Core API.

```swift
public struct GitHubWorkflowRunSupersessionResolution: Equatable, Sendable {
    public let currentRuns: [GitHubWorkflowRun]
    public let supersededRunIDs: Set<Int64>
}

public struct GitHubWorkflowRunSupersessionResolver: Sendable {
    public init() {}

    public func resolve(
        runs: [GitHubWorkflowRun]
    ) -> GitHubWorkflowRunSupersessionResolution
}
```

`currentRuns` preserves every non-superseded run and is deterministically ordered by the existing provider-visible ordering requirements. The resolver itself must not encode Inbox priority; it only removes proven superseded runs.

`suppersededRunIDs` exists for tests/diagnostics and future observability. It is not surfaced in Core UI in this phase.

## Provider Integration

`GitHubActivityProvider` injects/defaults one resolver dependency.

On each successful workflow repository response:

```text
raw runs
  -> resolver.resolve
  -> resolution.currentRuns
       -> visibleActivities(...)
       -> workflow evidence
  -> cache current activity/evidence
```

Superseded runs must be removed **before** both paths. This guarantees an obsolete head SHA cannot remain visible as Workflow activity and cannot keep generating Check Run candidates.

No additional request budget is consumed.

## Cache Semantics

Existing cache rules remain authoritative:

- a successful workflow load replaces that repository's cached Workflow activities/evidence with results derived from `currentRuns`;
- therefore a newly observed replacement run removes previously cached superseded activity/evidence in the same successful refresh;
- a failed workflow load keeps the existing last-known-good cache exactly as today;
- connection reset/repository deselection continues to clear the same cache entries;
- stale async completion rejection remains generation-based and unchanged.

Supersession itself does not need a separate long-lived cache.

## Check Candidate Semantics

This change intentionally affects Check discovery.

Workflow-derived Check candidates may only use evidence generated from `currentRuns`. If an old failed Workflow for SHA `aaa` is superseded by a newer run for SHA `bbb`, Workflow evidence for `aaa` disappears after the successful refresh.

Review-request-derived Check candidates remain independent. If GitHub's current open PR metadata still identifies SHA `aaa` as the requested-review head for some reason, the Review source may continue to make that SHA a candidate. Supersession must not overwrite stronger data from another source.

## Activity Identity and Detail Navigation

No `ActivityItem` identity format changes.

A current Workflow item continues using the existing GitHub run ID-based activity ID and trusted Workflow Run URL. Lazy job-detail loading therefore needs no new routing logic.

Once an older run becomes superseded it simply stops being emitted after the successful refresh. There is no synthetic redirect from an obsolete run to a new run.

## Ordering

The resolver must produce deterministic output independent of input order.

Recommended normalized ordering for `currentRuns` is:

1. `updatedAt` descending;
2. `runNumber` descending;
3. `id` descending.

The existing activity mapper and global Inbox sorter remain responsible for user-facing priority after supersession normalization.

## Failure and Ambiguity Policy

When evidence is incomplete or contradictory, keep data rather than suppress it.

Do not suppress when:

- there is not exactly one positive PR number;
- workflow IDs differ;
- events differ;
- newest normalized SHA is empty;
- an older normalized SHA is empty;
- duplicate maximum `runNumber` values exist in the lane;
- only branch/name/time similarity exists.

The false-negative bias is intentional. Stale noise is preferable to hiding a potentially independent failure without strong replacement evidence.

## Security and Performance

The resolver operates only on normalized GitHub DTO fields already in memory. It does not interpret URLs, YAML, shell content, job logs, or user-provided executable text.

Complexity is O(n log n) due to grouping/output ordering and O(n) memory. The existing per-repository workflow limit remains unchanged, so this work does not alter API/network cost.

## Testing Strategy

TDD must cover at least:

### Resolver unit tests

- old failed SHA -> newer running SHA suppresses old run;
- old failed SHA -> newer successful SHA suppresses old run;
- newest cancelled/skipped different SHA still supersedes old run;
- same SHA across newer run numbers keeps both;
- different `workflowID` keeps both;
- different `event` keeps both;
- different PR numbers keep both;
- zero PR numbers keep runs;
- multiple PR numbers keep runs;
- duplicate maximum `runNumber` keeps the entire lane;
- malformed/empty normalized SHA keeps the affected lane/runs conservatively;
- three-generation lane keeps only current-generation SHA plus any older same-SHA runs;
- deterministic output for shuffled input.

### Provider tests

- superseded Workflow activity disappears after a successful refresh;
- newer current Workflow remains visible according to existing classification rules;
- superseded Workflow evidence is removed before Check candidate planning;
- hidden successful current Workflow still contributes current-SHA evidence as today;
- workflow load failure preserves last-known-good cache;
- reset/generation isolation remains unchanged;
- request budgets are unchanged.

### Regression gates

- existing Workflow activity mapper tests remain unchanged unless fixture helpers need extension;
- existing Review/Check multi-source tests remain green;
- existing matrix-job detail tests remain green;
- no new Visual scene is required because the UI structure does not change;
- full CI, existing Visual Regression, and CodeQL must pass on the exact implementation head before merge.

## Implementation Files

Expected production changes:

- create `Sources/SchneeBarGitHubActivityProvider/GitHubWorkflowRunSupersessionResolver.swift`;
- modify `Sources/SchneeBarGitHubActivityProvider/GitHubActivityProvider.swift` to normalize successful workflow responses before activity/evidence mapping;
- optionally extend private workflow outcome plumbing only as needed to keep raw-to-normalized ownership clear;
- update `docs/DEVELOPMENT_PLAN.md` after implementation.

Expected tests:

- create `Tests/SchneeBarGitHubActivityProviderTests/GitHubWorkflowRunSupersessionResolverTests.swift`;
- extend `Tests/SchneeBarGitHubActivityProviderTests/GitHubActivityProviderTests.swift` with provider/cache/Check-candidate regression cases.

No Core, SwiftUI, GitHub REST client, job-detail, or Visual Harness production changes are expected.

## Acceptance Criteria

1. An older run is suppressed only when it shares `(workflowID, event, single PR)` with a higher-run-number current run on a different head SHA.
2. Same-SHA runs are never suppressed by this feature.
3. Branch-only and ambiguous-PR runs are never suppressed.
4. Newest cancelled/skipped runs still supersede obsolete different-SHA runs.
5. Superseded runs generate neither Workflow Inbox activity nor Workflow-derived Check evidence.
6. Review-derived Check candidates remain independent.
7. Successful refresh replaces cached stale activity/evidence; failed refresh preserves last-known-good behavior.
8. No new API request, workflow YAML fetch, or Core/UI state is added.
9. Existing correlation, re-run, matrix-detail, polling-budget, and generation-reset behavior remains intact.
10. Resolver output and tests are deterministic.
11. CI, Visual Regression, and CodeQL pass on the exact implementation head before merge.

## Review Result

Self-review found no blocking issue. The lane key, duplicate-maximum behavior, same-SHA preservation, Review-derived Check independence, deterministic ordering, and failure/cache semantics are explicit and internally consistent. Approved for implementation.

## Deferred Follow-up

Possible later work, deliberately excluded here:

- branch/push supersession if GitHub exposes sufficiently reliable concurrency/run-group evidence;
- `run_attempt` presentation/history for explicit re-run UX;
- user-visible superseded history/timeline;
- diagnostics counters for suppressed runs;
- enterprise-specific validation of unusual GHES workflow payload behavior.

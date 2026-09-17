# GitHub Matrix Job Aggregation Design

**Date:** 2026-09-17  
**Status:** Ready for written-spec review  
**Scope:** Phase 3 Developer Activity hardening

## Goal

Improve Workflow Run job detail readability when GitHub Actions expands one logical job into many similarly named matrix/variant jobs.

SchneeBar should collapse high-confidence repeated job-name variants into a compact parent row while preserving every underlying GitHub job as an inspectable child with its original state, failure detail, duration, and trusted destination URL.

The feature must remain conservative: GitHub's Workflow Jobs REST response does not expose matrix keys or values as structured fields, so SchneeBar must not invent semantic labels such as `os=macos` or `swift=6.3` from positional job-name text.

## Non-goals

This change does **not**:

- fetch or interpret workflow YAML;
- evaluate GitHub Actions expressions, `strategy.matrix`, `include`, or `exclude`;
- infer matrix key names from job-name values;
- add new GitHub REST requests;
- alter top-level Workflow Run polling or Activity Inbox ordering;
- implement superseded-run handling;
- correlate jobs across different workflow runs;
- change the GitHub workflow-job API pagination/filter policy;
- persist disclosure state across app launches;
- add a generic tree model for arbitrary nested provider data.

Superseded-run handling remains the next separate Phase 3 hardening item.

## Existing Architecture

Current Workflow detail flow is:

```text
ActivityItem (.workflowRun)
        |
        v
GitHubConnectionsRuntimeModel.loadActivityDetail(...)
        |
        v
GitHubWorkflowJobService
        |
        v
[GitHubWorkflowJob]
        |
        v
GitHubActivityJobDetailMapper
        |
        v
ActivityDetailSnapshot
        |
        v
ActivityDetailView
```

Relevant existing behavior:

- `GitHubActionsJobsClient` normalizes GitHub job payloads into `GitHubWorkflowJob`;
- `GitHubWorkflowJobSummary` already aggregates run-level counts and failure precedence;
- `GitHubActivityJobDetailMapper` currently emits one `ActivityDetailRow` per GitHub job;
- `ActivityDetailRow` is provider-neutral Core state;
- `ActivityDetailView` renders rows in a bounded scroll area and links each row to its trusted reconstructed GitHub job URL;
- job destination URLs are reconstructed from the trusted connection endpoint rather than trusting API `html_url` values.

The change keeps those boundaries. GitHub-specific grouping remains outside Core and SwiftUI.

## API Reality and Terminology

GitHub Actions may expand one logical matrix job into many jobs, and the displayed job names often contain variant values such as:

```text
Test (macos-15, swift-6.3)
Test (ubuntu-24.04, swift-6.3)
Test (windows-2025, swift-6.3)
```

However, the Workflow Jobs REST response does not provide a structured object like:

```text
matrix = { os: "macos-15", swift: "6.3" }
```

Therefore SchneeBar uses the term **variant group** internally and in user-facing copy where necessary. A variant group may correspond to a GitHub matrix expansion, but SchneeBar does not claim that it has proven matrix semantics.

This distinction is important for correctness: the app may group repeated names such as `Build (debug)` / `Build (release)` because they are presentation variants, but it must not assert that `debug` and `release` came from a matrix key.

## Design Decision

Add a small GitHub-specific job grouper before mapping jobs into provider-neutral detail rows.

```text
[GitHubWorkflowJob]
        |
        v
GitHubWorkflowJobGrouper
        |
        +-- single job
        +-- variant group
        |
        v
GitHubActivityJobDetailMapper
        |
        v
ActivityDetailSnapshot
        |
        v
ActivityDetailView
```

Do not fetch workflow YAML and do not parse arbitrary Actions expressions.

This approach adds no network cost, preserves existing normalized GitHub models, and keeps heuristic grouping isolated and independently testable.

## Variant Candidate Parsing

A job is a grouping candidate only when its **trimmed display name** has a terminal parenthesized suffix in this exact structural form:

```text
<Base name> (<variant label>)
```

Examples that are candidates:

```text
Test (macos-15)
Test (ubuntu-24.04)
Build (debug)
Build (release)
```

Examples that are not candidates:

```text
Build
Deploy production
Test (macos) retry
(macos)
Test ()
```

The parser returns:

```swift
struct GitHubWorkflowJobVariantName: Equatable, Sendable {
    let baseName: String
    let variantLabel: String
}
```

Parsing rules:

1. trim leading/trailing whitespace from the full job name;
2. require the final character to be `)`;
3. walk backward from that final `)` while balancing nested parentheses until the matching opening `(` for the terminal suffix is found;
4. require that opening `(` to be immediately preceded by one space, which separates the base name from the suffix;
5. trim the base and suffix contents independently;
6. require both the base and variant label to be non-empty;
7. preserve the variant label as opaque human-readable text;
8. do not split the variant label on commas, equals signs, slashes, spaces, or other punctuation;
9. do not synthesize matrix key names.

This means `Test (macos (arm64))` parses as base `Test` with opaque variant label `macos (arm64)`, while `Test (macos) retry` is not a candidate.

Unbalanced parentheses fail parsing and leave the job ungrouped.

## Group Formation

The grouping key is explicitly:

```text
(runID, baseName)
```

A variant group is formed only when all of the following are true:

1. at least two jobs share the same `runID` and exact parsed `baseName`;
2. all candidate jobs in that `(runID, baseName)` bucket have distinct non-empty `variantLabel` values;
3. each grouped job retains its own unique GitHub job ID;
4. no unparseable job is folded into the group.

The comparison of `baseName` and `variantLabel` is case-sensitive because GitHub job names are user-controlled display text and SchneeBar should not merge names the author intentionally distinguished by case.

The minimum group size is 2.

If duplicate variant labels appear inside one `(runID, baseName)` bucket, the entire candidate bucket remains ungrouped. This avoids hiding retries, generated duplicates, or custom jobs behind an ambiguous parent.

Examples:

```text
Test (macos)
Test (linux)
```

becomes one `Test` group with two children when both jobs belong to the same run.

```text
Test (macos)
Test (macos)
```

remains two independent rows.

```text
Build (debug)
Build (release)
Package
```

becomes one `Build` group plus one `Package` row.

Jobs from different workflow runs never group even when their names are identical.

## Why No Step-Signature Requirement

A stricter design could require matrix candidates to have identical step names/counts. SchneeBar will **not** require this.

Real matrix variants frequently contain conditional steps that differ by operating system, architecture, language version, or generated include entries. Requiring identical step signatures would incorrectly reject useful groups.

The grouping remains low-risk because it is presentation-only:

- no source jobs are discarded;
- child rows preserve exact job names and URLs;
- no semantic matrix keys are inferred;
- the user can expand the group and inspect every original job.

## GitHub-Specific Group Model

Add a small type in `SchneeBarGitHubActivityProvider`, not Core:

```swift
public struct GitHubWorkflowJobVariant: Equatable, Sendable {
    public let label: String
    public let job: GitHubWorkflowJob
}

public struct GitHubWorkflowJobVariantGroup: Equatable, Sendable {
    public let baseName: String
    public let variants: [GitHubWorkflowJobVariant]
}

public enum GitHubWorkflowJobPresentationEntry: Equatable, Sendable {
    case job(GitHubWorkflowJob)
    case variantGroup(GitHubWorkflowJobVariantGroup)
}

public struct GitHubWorkflowJobGrouper: Sendable {
    public init() {}

    public func entries(
        jobs: [GitHubWorkflowJob]
    ) -> [GitHubWorkflowJobPresentationEntry]
}
```

The exact public/internal visibility may be narrowed during implementation if tests can remain module-scoped, but the grouping logic must live in a dedicated type rather than inside SwiftUI.

## Deterministic Ordering

Top-level ordering continues to use existing detail priority semantics:

1. failed;
2. running;
3. waiting;
4. success;
5. neutral.

For a group, its aggregate state determines its top-level priority.

Within the same priority:

- groups sort by `baseName`;
- single jobs sort by full job name;
- ties fall back to a stable job/group identifier.

Children inside a group sort by:

1. failed;
2. running;
3. waiting;
4. success;
5. neutral;
6. `variantLabel`;
7. job ID.

This makes the problematic variant visible first after expansion.

## Aggregate Group State

Group state is derived from child presentation states with this precedence:

```text
failed > running > waiting > success > neutral
```

Examples:

- 1 failed + 4 success -> group `.failed`;
- 1 running + 3 success -> group `.running`;
- 1 waiting + 3 success -> group `.waiting`;
- all success -> group `.success`;
- cancelled/skipped/neutral-only -> group `.neutral`.

If a group mixes `.success` and `.neutral` only, `.success` wins because there is no active or failing work and at least one successful variant completed normally.

## Provider-Neutral Detail Tree

Extend `ActivityDetailRow` minimally with one level of children:

```swift
public struct ActivityDetailRow: Identifiable, Equatable, Sendable {
    public let id: String
    public let title: String
    public let detail: String?
    public let state: ActivityDetailState
    public let destinationURL: URL?
    public let children: [ActivityDetailRow]
}
```

The initializer adds:

```swift
children: [ActivityDetailRow] = []
```

This preserves all existing call sites.

Core does not gain GitHub-specific fields such as `matrix`, `variant`, `jobID`, or `runID`.

The tree depth for this feature is exactly one grouping level. Recursive provider-generated nesting is not a goal, even though the Core representation can naturally contain child rows.

## Mapping to Detail Rows

`GitHubActivityJobDetailMapper` receives the grouper as a dependency with a default production instance:

```swift
public init(
    grouper: GitHubWorkflowJobGrouper = GitHubWorkflowJobGrouper()
)
```

A single job maps exactly as it does today.

A variant group maps to one parent `ActivityDetailRow`:

```text
title:       base name
state:       aggregate child state
destination: nil
children:    one row per original GitHub job
```

Parent detail copy is deterministic and compact.

Base form:

```text
"N variants"
```

Append non-zero attention counts in this order:

```text
failed, running, waiting, cancelled
```

Examples:

```text
3 variants
3 variants · 1 failed
5 variants · 1 failed · 1 running
4 variants · 2 waiting
```

Successful counts are not appended because `N variants` already communicates total size and success-only groups need minimal copy.

Cancelled variants remain neutral children but contribute a `cancelled` count to parent detail text.

Skipped/stale/neutral variants do not add another parent count.

## Child Row Presentation

Each grouped child row preserves the original job state, URL, failure step, and duration logic.

The child `title` uses the opaque `variantLabel`, not a synthesized key/value representation.

Example:

```text
Test                         [failed]
  3 variants · 1 failed

  macos-15, swift-6.3        [failed]
    Failed at Test

  ubuntu-24.04, swift-6.3    [success]
    Succeeded · 42s

  windows-2025, swift-6.3    [success]
    Succeeded · 55s
```

Accessibility/help copy should make clear that children open individual GitHub jobs.

The complete original GitHub job name remains available in the model through `GitHubWorkflowJob`; if future accessibility needs require it, the child accessibility label may include both base and variant text without changing grouping semantics.

## UI Behavior

`ActivityDetailView` becomes group-aware without learning GitHub semantics.

Rules:

- rows with `children.isEmpty` render exactly as today;
- rows with children render as a `DisclosureGroup`-style row;
- group rows have no browser-link affordance because one parent does not correspond to one GitHub job;
- child rows keep the existing external-link affordance;
- groups are collapsed by default to preserve compact menu-bar behavior;
- expansion state is view-local and not persisted;
- disclosure interaction must not trigger a child browser link;
- the scroll height limit remains unchanged unless Visual Regression proves clipping/regression.

A group parent still displays the aggregate state icon, title, and detail text when collapsed, so failure/running state remains visible without expansion.

## Summary Semantics

`ActivityDetailSnapshot.summary` continues to use `GitHubWorkflowJobSummary(jobs:)` over the raw jobs.

Grouping therefore does not change run-level counts such as:

```text
8/10 jobs · 1 failed · 1 running
```

This is important: grouping is a detail presentation optimization, not a change to the underlying workflow-job accounting model.

## Failure Semantics

Existing failure-step behavior remains unchanged for child jobs.

If one variant fails:

- the parent group is `.failed`;
- its compact detail includes the failure count;
- the failed child sorts first;
- expanding the group exposes `Failed at <step>` on the exact child;
- opening that child uses its existing trusted reconstructed job URL.

No new failure state is introduced.

## Security and Trust Boundaries

This feature adds no new remote trust boundary.

Requirements:

- grouping uses only already-normalized `GitHubWorkflowJob` values;
- no remote HTML or Markdown is rendered;
- no arbitrary workflow YAML is downloaded or interpreted;
- no remote URL from job-name text is recognized;
- existing trusted job destinations remain unchanged;
- job-name and variant text are display strings only and must never influence filesystem paths, shell commands, API endpoints, or authentication state.

## Performance

Grouping is entirely local and bounded by the number of jobs already returned for one Workflow Run.

Current client limits remain the effective upper bound. The grouper should be approximately O(n log n) including deterministic sorting and use O(n) additional memory.

No network request, polling cadence, cache key, or rate-limit budget changes.

## Compatibility

### Core model

Adding `children` with a default empty array keeps existing source call sites compatible.

`ActivityDetailRow` is not currently persisted as long-lived user data, so no backward Codable migration is needed unless implementation inspection finds otherwise. If Codable is introduced or existing conformance is discovered during implementation, decoding must default missing children to `[]`.

### Existing job detail

Workflows with no eligible groups must render identically in behavior and ordering to the existing implementation.

Single parenthesized names such as `Build (release)` remain single jobs because a group requires at least two distinct variants sharing the same `(runID, baseName)` key.

## Deterministic IDs

Single rows keep the existing job-ID-based row ID.

Group parent IDs are deterministic and scoped to the Workflow Run, for example:

```text
"github-job-group:<runID>:<baseName>"
```

The implementation may escape or hash the base-name component if needed for robust identity, but IDs must be deterministic across repeated renders of the same normalized jobs.

Child rows keep their original job-ID-based identity.

## Visual Regression

Add deterministic fixtures with fictional job data only.

Required scenes:

1. **matrix-success-light** — one collapsed all-success variant group plus a normal single job;
2. **matrix-failure-light** — failed aggregate group visible without expansion;
3. **matrix-failure-dark** — same state in dark appearance.

If the current snapshot harness cannot deterministically force disclosure expansion without introducing production-only state, do not add an artificial production expansion flag merely for snapshots. Unit tests must instead fully verify child row contents/URLs; Visual Regression covers collapsed group layout.

## Testing Strategy

Use TDD.

### Grouper tests

Cover at least:

- two same-base variants group;
- three same-base variants group;
- single candidate remains ungrouped;
- duplicate variant labels disable grouping for that bucket;
- different bases do not group;
- same-looking candidates from different `runID` values do not group;
- terminal suffix only (`Test (macos) retry` does not parse);
- empty base/suffix rejection;
- balanced nested suffix such as `Test (macos (arm64))` remains one opaque variant label;
- unbalanced suffix stays ungrouped;
- deterministic output ordering.

### Mapper tests

Cover at least:

- failed child makes parent failed;
- running child makes otherwise-success parent running;
- waiting child makes otherwise-success parent waiting;
- all-success group maps to success;
- cancelled-only group maps to neutral;
- successful + cancelled group maps to success;
- failed child sorts before successful child;
- child title is only the opaque variant label;
- child keeps original destination URL;
- failed child keeps `Failed at <step>` detail;
- existing non-grouped mapper tests continue to pass unchanged or with only expected tree defaults.

### Core/UI tests

Cover at least:

- `ActivityDetailRow(children:)` default is empty;
- childless row behavior remains unchanged;
- group rows are recognized as locally expandable;
- group parent does not expose an external job destination;
- child link behavior remains available.

### Visual tests

Build/render the required deterministic scenes in the existing Visual Regression workflow.

## Implementation Files

Expected changes:

### Core / Activity feature

- `Sources/SchneeBarCore/ActivityDetail.swift`
- `Sources/SchneeBarActivityFeature/ActivityDetailView.swift`
- Core/feature tests for child-row and disclosure behavior

### GitHub Activity provider

- Create `Sources/SchneeBarGitHubActivityProvider/GitHubWorkflowJobGrouper.swift`
- Modify `Sources/SchneeBarGitHubActivityProvider/GitHubActivityJobDetailMapper.swift`
- Create `Tests/SchneeBarGitHubActivityProviderTests/GitHubWorkflowJobGrouperTests.swift`
- Extend `GitHubActivityJobDetailMapperTests.swift`

### Preview / Visual

- update deterministic detail fixtures in `SchneeBarPreviewSupport`;
- update Visual Harness and Visual Snapshot CLI as needed;
- update `docs/DEVELOPMENT_PLAN.md` after implementation lands.

No GitHub REST client/service file is expected to change.

## Acceptance Criteria

The feature is complete when all of the following hold:

1. eligible repeated terminal-parenthesized job variants collapse under one provider-neutral detail parent;
2. no matrix key/value semantics are invented;
3. groups require at least two distinct variants with the same `(runID, baseName)` key;
4. ambiguous duplicate-variant buckets remain ungrouped;
5. parent state accurately reflects failed/running/waiting/success/neutral child precedence;
6. every child preserves its original GitHub job destination and detail semantics;
7. workflows with no eligible groups preserve existing presentation behavior;
8. run-level summary counts remain based on raw jobs;
9. no new GitHub API request is made;
10. deterministic unit and Visual Regression coverage exists;
11. production CI, Visual Regression, and CodeQL pass on the exact implementation head before merge.

## Deferred Follow-up

After this work lands, Phase 3 hardening proceeds to **superseded-run handling**.

That follow-up should decide when older Workflow Runs for the same branch/PR/workflow become informational or disappear from the user-facing Inbox. It must be designed separately because it affects top-level activity identity/cache semantics rather than only Workflow detail presentation.

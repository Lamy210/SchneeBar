# GitHub Matrix Job Aggregation Design

**Date:** 2026-09-17  
**Status:** Approved after self-review  
**Scope:** Phase 3 Developer Activity hardening

## Goal

Improve Workflow Run job detail readability when GitHub Actions expands one logical job into many similarly named matrix/variant jobs.

SchneeBar should collapse high-confidence repeated job-name variants into a compact parent row while preserving every underlying GitHub job as an inspectable child with its original state, failure detail, duration, and trusted destination URL.

The feature must remain conservative: GitHub's Workflow Jobs REST response does not expose matrix keys or values as structured fields, so SchneeBar must not invent semantic labels such as `os=macos` or `swift=6.3` from positional job-name text.

## Non-goals

This change does **not** fetch/interpret workflow YAML, evaluate Actions matrix expressions, infer matrix key names, add GitHub REST requests, alter top-level Workflow polling/Inbox ordering, implement superseded-run handling, correlate jobs across runs, change job API pagination/filter policy, persist disclosure state, or introduce an arbitrary provider tree framework.

Superseded-run handling remains the next separate Phase 3 hardening item.

## Existing Architecture

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

`GitHubActionsJobsClient` already normalizes API payloads into `GitHubWorkflowJob`; `GitHubWorkflowJobSummary` owns run-level counts; `GitHubActivityJobDetailMapper` maps jobs to provider-neutral Core rows; `ActivityDetailView` renders those rows. Existing job URLs are reconstructed from the trusted GitHub connection endpoint.

## API Reality and Terminology

GitHub job names commonly look like:

```text
Test (macos-15, swift-6.3)
Test (ubuntu-24.04, swift-6.3)
Test (windows-2025, swift-6.3)
```

The Workflow Jobs REST response does not provide structured matrix keys/values. SchneeBar therefore calls the presentation concept a **variant group**. It may correspond to a GitHub matrix expansion, but SchneeBar never claims or synthesizes matrix semantics such as `os=...`.

## Design Decision

Add `GitHubWorkflowJobGrouper` inside `SchneeBarGitHubActivityProvider` before detail-row mapping. No workflow YAML fetch and no new network request.

```text
[GitHubWorkflowJob]
        |
        v
GitHubWorkflowJobGrouper
   |             |
 single job   variant group
        \       /
         v     v
GitHubActivityJobDetailMapper
        |
        v
ActivityDetailSnapshot
        |
        v
ActivityDetailView
```

## Variant Candidate Parsing

A candidate must have a trimmed terminal suffix in exact structural form:

```text
<Base name> (<variant label>)
```

Examples accepted: `Test (macos-15)`, `Build (release)`, `Test (macos (arm64))`.

Examples rejected: `Build`, `Test (macos) retry`, `(macos)`, `Test ()`, unbalanced parentheses.

The parser:

1. trims surrounding whitespace;
2. requires final `)`;
3. walks backward balancing nested parentheses until the matching terminal `(`;
4. requires exactly one ASCII space immediately before that `(`;
5. trims base and suffix contents;
6. rejects empty base/suffix;
7. keeps the suffix as opaque display text;
8. never splits commas/equal signs/slashes/spaces or invents key names.

## Group Formation

The grouping key is exactly `(runID, baseName)`.

A group forms only when at least two jobs in the same key parse successfully and every variant label in that bucket is distinct. Comparison is case-sensitive. Duplicate labels make the whole bucket remain ungrouped. Jobs from different runs never group.

Examples:

```text
Test (macos)
Test (linux)
```

becomes one `Test` group with two children.

```text
Test (macos)
Test (macos)
```

remains two independent rows.

Step-signature equality is intentionally not required because legitimate matrix variants may contain conditional OS/architecture-specific steps. Grouping is presentation-only and retains every original child job.

## GitHub-Specific Group Model

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

Grouping remains outside Core and SwiftUI.

## Deterministic Ordering and Aggregate State

Top-level and child state priority is:

```text
failed > running > waiting > success > neutral
```

Within equal state priority, groups/single jobs sort by display title then stable ID. Children then sort by opaque variant label and job ID.

Group state is the highest-priority child state. A success+neutral-only group is `.success`; neutral-only is `.neutral`.

## Provider-Neutral Detail Tree

Extend `ActivityDetailRow` with:

```swift
public let children: [ActivityDetailRow]
```

and initializer default:

```swift
children: [ActivityDetailRow] = []
```

Core gains no GitHub-specific matrix/variant fields. This feature generates one grouping level only.

## Mapping to Detail Rows

`GitHubActivityJobDetailMapper` receives a defaulted `GitHubWorkflowJobGrouper` dependency. A single job maps exactly as today.

A group parent has:

```text
title:       base name
state:       aggregate child state
destination: nil
children:    original jobs mapped to child rows
```

Parent detail begins `N variants` and appends nonzero counts in exact order: `failed`, `running`, `waiting`, `cancelled`. Cancelled count is derived from raw job conclusion; skipped/stale/neutral do not inflate it.

Each child title is the opaque variant label and retains the original normalized job URL, failure-step detail, duration, and state.

`ActivityDetailSnapshot.summary` remains based on raw `[GitHubWorkflowJob]`, so grouping never changes run-level job counts.

## UI Behavior

`ActivityDetailView` remains provider-neutral:

- childless destination row -> existing Link behavior;
- childless destinationless row -> existing plain row;
- child-bearing row -> local disclosure parent;
- disclosure parent is collapsed by default and has no external-link affordance;
- child rows keep job links;
- expansion is view-local/nonpersistent;
- scroll-height cap remains unchanged unless Visual Regression demonstrates a real layout issue.

The implementation uses an explicit testable interaction classifier so tests and SwiftUI consume the same decision.

## Security and Performance

Grouping consumes only already-normalized job display strings and models. Job-name text never influences filesystem paths, shell commands, API endpoints, URLs, or credentials. No HTML/Markdown/YAML is interpreted. Existing trusted job destinations remain unchanged.

Grouping is local, O(n log n) including sorting, O(n) memory, and adds no network request or polling/cache change.

## Deterministic IDs

Single rows retain job-ID identity. Group parent IDs are deterministic and run-scoped, e.g.:

```text
github-job-group:<runID>:<baseName>
```

Child rows retain job-ID identity.

## Visual Regression

Required deterministic scenes:

1. `matrix-success-light` — collapsed all-success group plus a normal single job;
2. `matrix-failure-light` — failed aggregate group visible while collapsed;
3. `matrix-failure-dark` — same failed state in dark appearance.

Do not add a production-only expanded-state control just for snapshots. Unit tests verify child content/URLs; Visual Regression verifies collapsed group layout.

## Testing Strategy

TDD covers:

- parser/grouping: 2/3 variants, one candidate, duplicate labels, distinct bases, distinct run IDs, terminal-only suffix, empty/unbalanced rejection, nested suffix opacity, deterministic output;
- mapper: failed/running/waiting/success/neutral precedence, cancelled count semantics, child sorting, child URL/failure detail, raw summary counts;
- Core/UI: children default, disclosure/link/none interaction classification;
- Visual: the three deterministic scenes above.

## Implementation Files

Core/feature:
- `Sources/SchneeBarCore/ActivityDetail.swift`
- `Sources/SchneeBarActivityFeature/ActivityDetailView.swift`
- corresponding tests

GitHub Activity provider:
- create `Sources/SchneeBarGitHubActivityProvider/GitHubWorkflowJobGrouper.swift`
- modify `Sources/SchneeBarGitHubActivityProvider/GitHubActivityJobDetailMapper.swift`
- grouper/mapper tests

Preview/Visual:
- `Sources/SchneeBarPreviewSupport/ActivityDetailFixtures.swift`
- Visual Harness / Snapshot CLI
- `docs/DEVELOPMENT_PLAN.md`

No GitHub REST client/service file changes.

## Acceptance Criteria

1. eligible repeated terminal-parenthesized variants collapse under one provider-neutral parent;
2. no matrix key/value semantics are invented;
3. groups require >=2 distinct variants with same `(runID, baseName)`;
4. duplicate-label buckets remain ungrouped;
5. parent state reflects child precedence;
6. children preserve original destinations/detail semantics;
7. non-grouped workflows preserve current behavior;
8. raw jobs continue to drive run-level summary counts;
9. no new GitHub API request is made;
10. deterministic unit and Visual Regression coverage exists;
11. CI, Visual Regression, and CodeQL pass on exact implementation head before merge.

## Review Result

Self-review found no blocking issue. The implementation plan fixes execution-level details: interaction classification is explicit/testable, cancelled counts derive from raw conclusions, parser/group IDs are deterministic, and exact snapshot names/commands are fixed. Approved for implementation.

## Deferred Follow-up

After this work, Phase 3 proceeds to **superseded-run handling**, designed separately because it changes top-level workflow activity identity/cache semantics rather than detail presentation only.

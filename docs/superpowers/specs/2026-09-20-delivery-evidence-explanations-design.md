# Delivery Confidence / Evidence Explanations — Phase 4 Sixth Vertical Slice

Date: 2026-09-20
Status: Approved for implementation from the continue-development instruction
Base: `main@878537b3066a3fb82e480217638dea07f5637ee3`

## 1. Purpose

Explain why a Delivery correlation is trusted, why it is unavailable, and when evidence could not be checked, without adding any GitHub API requests.

The current UI exposes only a confidence label such as `Exact correlation`. The provider already evaluates concrete evidence but discards the explanation before the snapshot reaches Core. This slice preserves a minimal provider-neutral evidence checklist and renders it in Activity detail.

## 2. Goals

- Explain correlated Delivery evidence with concrete, non-sensitive statements.
- Explain missing evidence without inventing a relationship.
- Explain technical evidence-loading failures distinctly from missing evidence.
- Preserve the current Delivery confidence/status semantics.
- Add zero HTTP requests and zero permission expansion.
- Never expose raw commit SHA, credential material, actor identity, API payloads, or internal GitHub DTOs.
- Keep the 340-point Activity detail layout readable.
- Preserve Deployment/Environment best-effort behavior.

## 3. Non-Goals

- No new correlation algorithm.
- No confidence scoring percentages.
- No user-configurable scoring weights.
- No raw evidence JSON.
- No commit SHA display.
- No actor/reviewer identity display.
- No additional GitHub endpoint.
- No telemetry backend.
- No persisted evidence history.
- No generic cross-provider evidence engine beyond the small provider-neutral Core contract required by current UI.

## 4. Core Contract

Add:

```swift
public enum DeliveryTimelineEvidenceState: String, Codable, CaseIterable, Sendable {
    case confirmed
    case missing
    case unavailable
}

public struct DeliveryTimelineEvidenceItem: Identifiable, Equatable, Sendable {
    public let id: String
    public let title: String
    public let detail: String?
    public let state: DeliveryTimelineEvidenceState
}
```

Extend `DeliveryTimelineSnapshot`:

```swift
public let evidence: [DeliveryTimelineEvidenceItem]

public init(
    status: DeliveryTimelineStatus,
    confidence: DeliveryTimelineConfidence,
    events: [DeliveryTimelineEvent],
    evidence: [DeliveryTimelineEvidenceItem] = []
)
```

The default keeps existing call sites source-compatible.

## 5. Evidence Semantics

Evidence items are explanatory facts/checks. They do not independently establish correlation outside the existing builder.

### Confirmed

Used only when the underlying existing data proves the statement.

Examples:
- `Workflow pull request` — `Selected workflow is attached to PR #47`
- `Merged pull request` — `PR #47 is merged`
- `Final pull request revision` — `Selected workflow represents the merged pull request's final revision`
- `Target branch execution` — `A workflow execution was found on target branch main`
- `Commit association` — `Target-branch execution is associated with PR #47`

### Missing

Used when the correlation path cannot be proven from available provider data.

Examples:
- `Workflow pull request` — `Workflow does not identify exactly one pull request`
- `Merged pull request` — `Merged pull request metadata is unavailable`
- `Target branch` — `Pull request target branch is unavailable`
- `Target branch execution` — `No eligible workflow execution was found on the target branch`
- `Commit association` — `No target-branch execution commit was associated with the pull request`

Missing means evidence is absent/ambiguous. It does not mean the delivery did not happen.

### Unavailable

Used for technical loading failures where evidence could not be checked.

Example:
- `Delivery evidence` — `GitHub evidence could not be loaded right now`

This state is used for `.temporarilyUnavailable`; it must not be used to describe ordinary missing evidence.

## 6. Builder Behavior

`GitHubDeliveryTimelineBuilder` remains the authority for correlation.

The builder constructs a deterministic evidence checklist while evaluating the existing gates.

For a successful exact merged-PR correlation, the checklist contains only confirmed entries and does not expose SHA values.

For `.evidenceUnavailable`, the checklist includes the successfully established prerequisites followed by the first material missing/ambiguous gate. This keeps explanations compact and deterministic.

Required decision order:

1. selected Workflow identifies exactly one positive PR number;
2. Pull Request metadata exists and matches that PR;
3. Pull Request is merged and has merge time;
4. target/base branch is non-empty;
5. eligible distinct target-branch execution exists with a usable commit identity;
6. target-branch commit association includes the PR;
7. existing correlator returns non-unknown confidence.

Do not weaken any current correlation gate.

## 7. Correlated Evidence Details

For a successful correlation:

1. `Workflow pull request`
   - `Selected workflow is attached to PR #N`

2. `Merged pull request`
   - `PR #N is merged`

3. `Final pull request revision`
   - confirmed only after existing correlator validation establishes the selected PR workflow as the final revision
   - no SHA is displayed

4. `Target branch execution`
   - `Workflow execution found on target branch <branch>`
   - default-branch wording may be used only when existing exact default-branch metadata proves it

5. `Commit association`
   - `Target-branch execution is associated with PR #N`

The UI does not show internal correlation reason enum names.

## 8. Deployment Evidence

Deployment enrichment may append one confirmed explanation when at least one Deployment event is appended:

- title: `Deployment commit match`
- detail:
  - singular: `1 deployment matched the correlated execution commit`
  - plural: `N deployments matched the correlated execution commit`

No SHA is displayed.

Environment metadata is presentation enrichment and does not add a correlation evidence item.

If Deployment loading fails or returns no matching deployments, preserve the existing PR/merge/execution evidence unchanged. Do not add a missing/unavailable Deployment evidence item because Deployment is optional enrichment, not a prerequisite for the core correlation.

## 9. Technical Failure Composition

In `GitHubConnectionsRuntimeModel+ActivityDetail`, when Delivery evidence loading throws a non-cancellation error:

```swift
DeliveryTimelineSnapshot(
    status: .temporarilyUnavailable,
    confidence: .unknown,
    events: [],
    evidence: [
        DeliveryTimelineEvidenceItem(
            id: "delivery-evidence-load",
            title: "Delivery evidence",
            detail: "GitHub evidence could not be loaded right now",
            state: .unavailable
        )
    ]
)
```

Jobs remain successfully loaded, as today.

## 10. UI

Keep the existing confidence label.

Below correlated events or unavailable copy, render a compact disclosure:

- correlated: `Why this correlation`
- evidence unavailable: `Why correlation is unavailable`
- temporarily unavailable: `Why evidence could not be checked`

Do not render the disclosure when `evidence.isEmpty`, preserving compatibility for older fixtures/callers.

Evidence icons:
- confirmed: `checkmark.circle.fill`
- missing: `questionmark.circle.fill`
- unavailable: `exclamationmark.triangle.fill`

Presentation:
- title: caption/medium
- detail: caption2/secondary
- no links
- no copy buttons
- at most the deterministic checklist produced by the builder

## 11. Request / Cost Invariants

This slice must perform zero new HTTP requests.

Existing ceilings remain:
- explicit detailed Delivery path: 12 feature HTTP requests
- standalone Delivery history: 1 feature HTTP request

No new permission or endpoint family is introduced.

## 12. Security / Privacy

Must not expose:
- raw SHA;
- actor identity;
- reviewer identity;
- credential/token;
- raw API URL or provider payload;
- hidden repository metadata beyond branch names and PR number already shown elsewhere.

Evidence strings are normalized inside provider/runtime composition before entering Core.

## 13. Tests

### Core
- default evidence is empty;
- evidence construction/equality;
- states remain distinct.

### Builder
- exact correlation emits deterministic confirmed checklist;
- raw selected/base SHA absent from every evidence title/detail;
- ambiguous selected PR emits missing Workflow pull request item;
- missing PR metadata emits missing Merged pull request item;
- non-merged PR emits missing Merged pull request item;
- blank base branch emits missing Target branch item;
- no eligible branch run emits missing Target branch execution item;
- missing commit association emits missing Commit association item;
- successful Deployment append adds exact one deployment-match evidence item;
- repeated Deployment append does not duplicate evidence item.

### Runtime
- Delivery loader technical failure creates one `.unavailable` evidence item;
- cancellation behavior unchanged;
- Jobs success remains preserved.

### UI
- disclosure label for all three statuses;
- icon mapping;
- no evidence => no disclosure.

### Visual
Light/Dark:
- exact correlation with expanded evidence;
- evidence unavailable;
- temporarily unavailable;
- deployment correlation with deployment evidence.

## 14. Acceptance Criteria

- Existing correlation gates are unchanged.
- Exact correlation explains the concrete evidence used.
- Missing evidence identifies the first material unresolved gate without claiming failure of the delivery.
- Technical failure is visibly distinct from missing evidence.
- No raw SHA appears in the Core evidence explanation.
- No additional HTTP requests are performed.
- Existing 12-request and 1-request budgets remain unchanged.
- CI, Visual Regression, and CodeQL pass on the exact implementation head.

## 15. Deferred Follow-up

- persisted Delivery history/evidence;
- richer user-facing correlation education/help;
- provider-independent evidence localization;
- local history-row drill-down;
- recovery notifications.

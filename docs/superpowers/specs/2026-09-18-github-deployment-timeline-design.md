# GitHub Deployment Timeline — Phase 4 Second Vertical Slice Design

Date: 2026-09-18  
Status: Proposed for written-spec review  
Base: `main@6a7ac415ee6676d579697c757a5b319d9d3f8d62`

## Context

Phase 4 now has an evidence-backed, demand-driven Delivery Timeline for a selected Workflow Activity detail:

`Pull Request workflow → merge → correlated base-branch execution`

The first slice deliberately stops at the correlated base-branch execution. The next product step is to show whether that exact revision was deployed and to which environment, without turning Deployment data into a new background Activity source.

SchneeBar already has repository capability assessment for `.deployments`, but that capability is not yet surfaced in repository-management UI and no Deployment REST adapter exists.

GitHub's Deployment API accepts an exact `sha` filter and returns deployment records containing environment metadata. Deployment statuses expose the lifecycle result for a deployment. Repository Environment APIs are separate and have additional capability semantics; they are not required to display the first deployment event in an already-correlated timeline.

## Goals

1. Extend the existing Delivery Timeline with deployment evidence for the exact correlated base execution SHA.
2. Keep all Deployment loading demand-driven: opening Workflow detail is still the only trigger.
3. Preserve the existing PR/merge/execution timeline when Deployment access is unavailable, evidence is absent, or Deployment loading fails.
4. Add no heuristic correlation. Deployment evidence must be tied to the exact correlated execution SHA.
5. Keep the total explicit-detail request budget bounded and testable.
6. Surface Deployment capability independently in repository-management UI.
7. Provide deterministic Light/Dark visual coverage.

## Non-goals

This slice does not implement:

- repository Environment inventory;
- Environment protection rules, reviewers, wait timers, or branch policies;
- deployment write actions;
- a standalone Deployments Activity source;
- background Deployment polling;
- persisted deployment history;
- release correlation;
- provider-generic deployment adapters beyond the Core timeline event;
- recovery notifications;
- repository default-branch discovery.

## Chosen Approach

Extend the existing Workflow detail enrichment path rather than adding a new Activity source.

The existing correlated base execution remains the authority for the revision being investigated. Once the base execution is proven, SchneeBar uses its exact `headSHA` to query deployments. No Deployment request is made when the base execution is not correlated.

Logical flow:

```text
Workflow detail open
      |
      +--> Workflow Jobs -------------------------- required
      |
      +--> Delivery correlation evidence --------- best effort
               |
               +--> exact PR -> merge -> execution proven?
                              |
                              no -> existing timeline only
                              |
                              yes
                              |
                              +--> deployments?sha=<exact SHA>
                                      |
                                      +--> latest statuses
                                      |
                                      +--> deployment events appended
```

This preserves the current product rule: normal Developer Activity polling remains asleep with respect to Delivery-specific evidence.

## Core Timeline Contract

Extend `DeliveryTimelineEventKind` with:

```swift
case deployment
```

No provider-specific deployment model enters `SchneeBarCore`.

A deployment is represented as an ordinary `DeliveryTimelineEvent`:

- `kind = .deployment`;
- title: `Deployment · <environment>`;
- detail: normalized status label, optionally with production/transient context;
- state: existing `ActivityDetailState`;
- destination URL: only when an explicit, sanitized status URL is safe to expose;
- `occurredAt`: latest normalized deployment-status timestamp when present.

The existing timeline status/confidence still describe the PR/merge/execution correlation. Deployment enrichment must not downgrade an exact correlation merely because no deployment is found.

## GitHub Deployment Models

Add normalized GitHub-layer models:

```swift
public struct GitHubDeployment: Equatable, Sendable {
    public let id: Int64
    public let sha: String
    public let environment: String
    public let isProductionEnvironment: Bool
    public let isTransientEnvironment: Bool
    public let createdAt: Date?
    public let updatedAt: Date?
}

public enum GitHubDeploymentStatusState: Equatable, Sendable {
    case pending
    case queued
    case inProgress
    case success
    case failure
    case error
    case inactive
    case unknown(String)
}

public struct GitHubDeploymentStatus: Equatable, Sendable {
    public let id: Int64
    public let state: GitHubDeploymentStatusState
    public let environment: String?
    public let description: String?
    public let environmentURL: URL?
    public let logURL: URL?
    public let createdAt: Date?
    public let updatedAt: Date?
}
```

Provider DTOs remain private to the REST client.

## Deployment REST Client

Create `GitHubDeploymentClient` in `SchneeBarGitHub`.

Required operations:

```swift
public func deployments(
    sha: String,
    repository: GitHubRepositoryAccess,
    connection: GitHubConnection,
    credential: GitHubCredential,
    limit: Int = 20
) async throws -> [GitHubDeployment]

public func latestStatus(
    deploymentID: Int64,
    repository: GitHubRepositoryAccess,
    connection: GitHubConnection,
    credential: GitHubCredential
) async throws -> GitHubDeploymentStatus?
```

### Deployment list request

Use:

`GET /repos/{owner}/{repo}/deployments?sha={exactSHA}&per_page=20&page=1`

Rules:

- SHA is required, trimmed, and non-empty;
- only page 1 is fetched;
- `per_page` is capped at 20 for this feature path;
- returned deployment SHA must exactly equal the requested normalized SHA;
- invalid IDs/payloads are rejected rather than partially trusted;
- GitHub.com/GHE.com REST API version policy follows existing clients;
- GHES uses the existing negotiated/explicit version behavior.

The client may expose a general list method later, but this slice needs only the exact-SHA bounded behavior.

### Deployment status request

Use:

`GET /repos/{owner}/{repo}/deployments/{deployment_id}/statuses?per_page=1&page=1`

Only the first/latest status is needed.

Status loading is performed for at most three deployments.

## URL Normalization

Deployment status URLs may point outside GitHub.

For this slice, `environmentURL` and `logURL` are retained only when all of the following hold:

- scheme is `https`;
- host is non-empty;
- URL contains no username or password;
- URL is absolute.

No URL is reconstructed from untrusted response host data.

The UI link priority is:

1. sanitized `environmentURL`;
2. sanitized `logURL`;
3. no link.

This is an explicit user-clicked destination; SchneeBar never automatically navigates to it.

## Deployment Enrichment Service

Do not add Deployment calls directly to SwiftUI or App Runtime.

Add a focused GitHub-layer service:

```swift
public struct GitHubDeploymentTimelineEvidence: Equatable, Sendable {
    public let deployments: [GitHubDeploymentEvidence]
}

public struct GitHubDeploymentEvidence: Equatable, Sendable {
    public let deployment: GitHubDeployment
    public let latestStatus: GitHubDeploymentStatus?
}

public protocol GitHubDeploymentTimelineLoading: Sendable {
    func deploymentEvidence(
        connection: GitHubConnection,
        identity: GitHubAccountIdentity,
        clientID: String?,
        repository: GitHubRepositoryAccess,
        exactSHA: String
    ) async throws -> GitHubDeploymentTimelineEvidence
}
```

Concrete `GitHubDeploymentTimelineService` owns the session coordinator and Deployment client.

Rules:

- authorize once;
- list deployments once for exact SHA;
- sort deterministically before status requests;
- inspect at most three deployments;
- request one latest status per inspected deployment;
- preserve cancellation immediately;
- return an empty evidence collection when no exact-SHA deployment exists.

### Deterministic deployment ordering

For the bounded first slice:

1. production deployments before non-production;
2. non-transient before transient;
3. `updatedAt` descending;
4. `createdAt` descending;
5. deployment ID descending.

Ordering determines which three deployments receive status requests. Ordering itself is presentation/request planning, not correlation evidence.

## Correlation Rule

Deployment correlation is deliberately simpler and stronger than the PR/merge correlation:

> A Deployment is eligible only when the deployment's normalized SHA exactly equals the already-proven correlated base execution `headSHA`.

Never correlate using only:

- environment name;
- branch/ref text;
- deployment timestamp;
- workflow name;
- status URL;
- PR number without exact revision evidence.

If the existing timeline has no proven base execution, no Deployment request is made.

## Builder Integration

Extend `GitHubDeliveryTimelineBuilder` with a separate enrichment operation rather than teaching its initial PR correlation pass to perform network work.

Suggested API:

```swift
public func appendDeployments(
    to timeline: DeliveryTimelineSnapshot,
    evidence: GitHubDeploymentTimelineEvidence
) -> DeliveryTimelineSnapshot
```

The builder remains pure.

Rules:

- preserve all original events and their order;
- append deployment events after the base execution;
- omit deployment entries whose normalized deployment SHA does not match the proven exact SHA supplied to the service;
- map status independently per deployment;
- when status is missing, render a neutral Deployment event rather than inventing success/failure.

The service is called only after App composition has obtained a correlated timeline and can identify the exact base execution SHA from provider evidence.

## Status Mapping

Map Deployment status to the existing detail state:

| GitHub status | ActivityDetailState | UI label |
| --- | --- | --- |
| `success` | `.success` | Succeeded |
| `failure` | `.failed` | Failed |
| `error` | `.failed` | Error |
| `in_progress` | `.running` | Running |
| `pending` | `.waiting` | Pending |
| `queued` | `.waiting` | Queued |
| `inactive` | `.neutral` | Inactive |
| unknown | `.neutral` | provider value when safe, otherwise Unknown |
| no status | `.neutral` | Status unavailable |

No deployment state changes the job-detail aggregate state.

## Environment Presentation

Environment API is intentionally deferred.

For this slice, the display environment comes from normalized Deployment / Deployment Status payload fields:

- prefer non-empty latest-status environment when present;
- otherwise use deployment environment;
- if both are empty, use `Unknown environment`.

Optional context:

- production: `Production`;
- transient: `Transient`.

Do not infer production from environment names such as `prod`, `production`, or `live`.

## Capability Gating

The existing repository capability evaluator already understands `.deployments`.

Extend `GitHubRepositoryActivityAccessModel` with:

```swift
public let deployments: GitHubRepositoryActivityAccessPresentation
```

Repository management displays Deployments independently alongside Actions / Reviews / Checks.

Runtime behavior:

- `.available`: Deployment enrichment may execute;
- `.unavailable`: skip Deployment network calls and preserve the existing timeline;
- `.unknown`: allow the explicit user-triggered detail request, matching the existing conservative requestability principle for uncertain capability evidence.

This slice does not require Environment capability because Environment API is not called.

## Failure Isolation

Jobs remain required exactly as today.

Delivery correlation remains best effort exactly as today.

Deployment enrichment is a third, narrower best-effort layer:

```text
Jobs failure
  -> detail fails as today

Jobs success + timeline correlation failure
  -> existing temporarily-unavailable timeline behavior

Jobs success + correlated timeline + deployment unavailable/no evidence
  -> PR/merge/execution timeline remains intact

Jobs success + correlated timeline + deployment technical failure
  -> PR/merge/execution timeline remains intact
  -> deployment events omitted
```

Do not replace the entire timeline with `.temporarilyUnavailable` merely because Deployment enrichment fails.

Raw Deployment errors never enter Core/UI models.

## Request Budget

Existing first-slice Delivery correlation budget:

- 1 exact workflow run;
- 1 PR metadata;
- 1 base-branch workflow list;
- up to 4 commit → PR association requests.

Maximum: 7 HTTP requests.

Deployment enrichment adds:

- 1 exact-SHA deployment list;
- up to 3 latest-status requests.

New maximum explicit-detail Delivery budget:

**11 HTTP requests**

This is a hard network cap, not a logical-method cap.

Tests must use recorded HTTP requests to prove the cap.

No deployment pagination beyond page 1 is allowed in this slice.

## Cancellation

All deployment requests are sequential.

Before each status request, call `Task.checkCancellation()`.

Cancellation must stop remaining status requests and propagate upward as `CancellationError`. App composition preserves the existing selected-item identity guard, so stale/dismissed detail cannot repopulate the UI.

## UI

The existing Delivery section remains one ordered timeline.

Example:

```text
Delivery                                  Exact correlation

✓ PR #49 workflow
  feat/deployment-timeline → main

✓ Merged
  into main

✓ Base branch · CI
  Succeeded

✓ Deployment · production
  Succeeded · Production

Jobs
4/4 jobs
...
```

Additional rules:

- deployment events use the same state icon/color language as other timeline events;
- no raw SHA is displayed;
- do not call the PR base branch the repository default branch;
- external deployment URLs use the existing external-link affordance;
- preserve the existing 340-point detail width initially;
- multiple deployment events remain in builder-supplied order.

## Visual Coverage

Add deterministic scenarios for both Light and Dark appearances:

1. production deployment succeeded;
2. staging/non-production deployment running;
3. correlated timeline with no deployment evidence;
4. Deployment capability unavailable / enrichment skipped;
5. multiple deployments with the three-item bound represented.

Visual fixtures contain only synthetic public-safe URLs and repository names.

## Security and Privacy

- no additional write permission;
- no token, credential, private endpoint, or real private environment name in fixtures;
- no `pull_request_target`;
- third-party actions remain immutable-SHA pinned;
- provider payloads are normalized before Core/UI;
- external status URLs are sanitized before presentation;
- no automatic navigation to deployment target URLs.

## Expected Files

Likely production changes:

- modify `Sources/SchneeBarCore/DeliveryTimeline.swift`;
- create `Sources/SchneeBarGitHub/GitHubDeploymentClient.swift`;
- create `Sources/SchneeBarGitHub/GitHubDeploymentTimelineService.swift`;
- modify `Sources/SchneeBarGitHubActivityProvider/GitHubDeliveryTimelineBuilder.swift`;
- modify `Sources/SchneeBarApp/GitHubConnectionsRuntimeModel+ActivityDetail.swift`;
- modify `Sources/SchneeBarApp/SchneeBarApp.swift`;
- modify `Sources/SchneeBarGitHubFeature/GitHubConnectionManagementView.swift`;
- modify `Sources/SchneeBarApp/GitHubConnectionsRuntimeModel.swift`;
- extend `Sources/SchneeBarPreviewSupport`;
- extend Visual Harness and Snapshot CLI;
- update `docs/DEVELOPMENT_PLAN.md`.

Corresponding Core, GitHub, GitHubActivityProvider, App, Feature, and visual tests are required.

## Testing Strategy

Development remains TDD.

### Core

- `.deployment` event kind round-trip/value distinction;
- existing timeline order remains stable.

### GitHubDeploymentClient

- exact endpoint paths;
- exact `sha` query;
- `per_page=20&page=1`;
- deployment/status decoding;
- unknown status preservation;
- trusted endpoint/API-version behavior;
- invalid SHA/ID/credential behavior;
- external status URL sanitization;
- no pagination.

### GitHubDeploymentTimelineService

- one authorization path;
- exact-SHA list only;
- deterministic ordering;
- maximum three status requests;
- total enrichment cap of four requests;
- empty deployment set stops after one request;
- cancellation prevents later status requests.

### Builder

- appends deployment after execution;
- exact event order preserved;
- environment naming rules;
- production/transient labels;
- status mapping;
- no-status neutral event;
- unrelated/mismatched deployment evidence never appears.

### App Runtime

- deployment capability unavailable causes zero Deployment requests;
- unknown capability remains requestable;
- Deployment technical error leaves correlated timeline intact;
- no Deployment request when correlation is unavailable;
- successful enrichment returns original Jobs + extended timeline;
- cancellation/stale selection semantics remain intact.

### Capability UI

- Deployments access renders available / unverified / unavailable independently.

### Visual

- deterministic Light/Dark scenarios listed above.

## Acceptance Criteria

1. A correlated Workflow detail can append Deployment events after the base execution.
2. Deployment evidence is queried only for the exact correlated base execution SHA.
3. Branch/time/environment-name similarity never establishes deployment correlation.
4. Background Activity polling makes zero Deployment requests.
5. Deployment enrichment performs at most four HTTP requests.
6. The full explicit-detail Delivery path performs at most eleven HTTP requests.
7. Deployment technical failure never hides Jobs or the already-correlated PR/merge/execution timeline.
8. Missing Deployment permission skips enrichment without turning the whole timeline into an error.
9. Unknown capability remains explicitly requestable.
10. Environment API is not called in this slice.
11. External Deployment URLs are sanitized and only opened by explicit user action.
12. GitHub DTOs do not leak into Core or SwiftUI.
13. Repository-management UI surfaces Deployments capability independently.
14. Deterministic Light/Dark visual scenarios cover success, running, absent, and capability-gated states.
15. Final implementation head passes CI, Visual Regression, and CodeQL before merge.

## Deferred Follow-up

- repository Environment inventory;
- Environment protection rules and required reviewers;
- standalone Deployment Activity / notifications;
- persisted deployment history;
- deployment history beyond first-page bounds;
- release correlation;
- repository default-branch metadata;
- recovery notifications;
- richer evidence explanations.

## Self-review Checklist

Before implementation planning:

- no `TODO` or `TBD`;
- no Environment API dependency remains hidden;
- request limits are defined as HTTP requests;
- correlation authority is exact SHA only;
- capability behavior is explicit for available/unavailable/unknown;
- failure isolation preserves existing timeline and Jobs;
- external URL handling is explicit;
- scope is one vertical slice rather than a full deployment subsystem.

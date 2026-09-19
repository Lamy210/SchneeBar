# GitHub Environment Enrichment — Phase 4 Third Vertical Slice Design

Date: 2026-09-20  
Status: Proposed — awaiting written-spec review  
Stacked base: `feat/github-deployment-timeline@69572a619c013273050565a1171fb04ae0644f81`  
Dependency: PR #51 (`feat: add GitHub deployment timeline enrichment`)

## Context

Phase 4 already has an evidence-backed, demand-driven Delivery Timeline:

`Pull Request workflow → merge → correlated base-branch execution → exact-SHA deployment`

PR #51 adds the second vertical slice:

- exact-SHA GitHub Deployment loading;
- at most three Deployment status lookups;
- a four-request Deployment enrichment cap;
- a complete explicit-detail Delivery cap of eleven feature HTTP requests;
- Deployment capability presentation;
- best-effort failure isolation that preserves Jobs and the existing Delivery timeline;
- no background Deployment polling.

The next useful increment is not a standalone Environment browser. It is a narrow enrichment of already-proven Deployment events with repository Environment protection metadata.

GitHub's repository Environment list endpoint returns built-in Environment protection information in the same response, including wait timers, required reviewers, and branch-policy mode. The endpoint supports `per_page=100`, requires Actions read permission for private repositories, and can be used without that permission for public resources.

Relevant GitHub documentation:

- `GET /repos/{owner}/{repo}/environments`: https://docs.github.com/en/rest/deployments/environments
- Environment names are case-insensitive and unique within a repository: https://docs.github.com/en/actions/how-tos/deploy/configure-and-manage-deployments/manage-environments
- Custom deployment protection rules are a separate endpoint family and remain out of scope: https://docs.github.com/en/rest/deployments/protection-rules
- Custom deployment branch-policy patterns are a separate endpoint family and remain out of scope: https://docs.github.com/en/rest/deployments/branch-policies

This slice deliberately uses only the repository Environment list endpoint.

## Goals

1. Enrich existing exact-SHA Deployment timeline events with built-in Environment protection metadata.
2. Keep Environment loading demand-driven and triggered only while opening Workflow detail.
3. Add no Environment request when no eligible Deployment evidence exists.
4. Add at most one Environment HTTP request per explicit detail load.
5. Raise the complete explicit-detail Delivery feature-request ceiling only from eleven to twelve.
6. Keep the existing Deployment event as the source of deployment correlation; Environment data must never establish correlation.
7. Preserve the existing Deployment timeline unchanged when Environment capability is unavailable, the Environment is not on page 1, the response is ambiguous, or loading fails.
8. Keep GitHub Environment DTOs inside `SchneeBarGitHub`.
9. Avoid exposing reviewer identities, environment secrets, or custom protection-rule integrations.
10. Add deterministic Light/Dark visual coverage for protected and unenriched Deployment states.

## Non-goals

This slice does not implement:

- a standalone repository Environment browser;
- Environment creation, update, or deletion;
- Environment secrets or variables;
- Environment reviewer identity display;
- approval actions;
- pending-deployment review actions;
- custom deployment protection-rule enumeration;
- custom deployment protection-rule app identity;
- custom deployment branch-policy pattern enumeration;
- pagination beyond Environment list page 1;
- Environment persistence or caching across detail loads;
- background Environment polling;
- recovery notifications;
- repository default-branch discovery;
- standalone Deployment history;
- deployment re-run/cancel/write actions.

## Chosen Approach

Fetch the repository Environment catalog once, only after exact-SHA Deployment evidence exists.

Logical flow:

```text
Workflow detail open
      |
      +--> Workflow Jobs -------------------------------- required
      |
      +--> Delivery correlation ------------------------- best effort
               |
               +--> exact base execution proven?
                        |
                        no -> stop Delivery enrichment
                        |
                        yes
                        |
                        +--> exact-SHA Deployments ------- best effort
                                  |
                                  +--> zero deployments?
                                  |       |
                                  |       yes -> stop; zero Environment requests
                                  |
                                  +--> one or more bounded deployments
                                          |
                                          +--> Actions capability unavailable?
                                          |       |
                                          |       yes -> keep Deployment events unchanged
                                          |
                                          +--> GET repository environments page 1
                                                  |
                                                  +--> match by normalized environment name
                                                  |
                                                  +--> append compact built-in protection metadata
```

Environment enrichment runs after Deployment evidence loading because an Environment record alone is not evidence that the exact correlated revision was deployed.

## Why Repository List Instead of Per-Environment Requests

### Selected: one repository Environment list request

Use:

`GET /repos/{owner}/{repo}/environments?per_page=100&page=1`

Advantages:

- one additional feature HTTP request regardless of whether one, two, or three Deployments are displayed;
- one authorization path for the Environment service;
- built-in protection rules are already returned by the list response;
- deterministic bounded behavior;
- simple failure isolation;
- easy combined twelve-request regression test.

Trade-off:

- repositories with more than one hundred Environments can leave a Deployment environment unmatched when it is not on page 1.

That trade-off is accepted for this slice. An unmatched Environment is not an error and must leave the Deployment event unchanged.

### Rejected: one `GET environment` request per Deployment

This avoids the one-hundred-Environment page bound but raises the maximum Delivery path from twelve to fourteen feature requests and duplicates network work for the common case.

### Rejected: standalone Environment browser first

This would require independent pagination, navigation, broader UI state, custom protection-rule decisions, and a repository-management surface. It is too broad for the next vertical slice.

## Request Budget

Existing maximum from PR #51:

- Delivery correlation: at most 7 feature HTTP requests;
- Deployment enrichment: at most 4 feature HTTP requests.

Existing total:

**11 feature HTTP requests**

Environment enrichment adds:

- Environment list: at most 1 feature HTTP request.

New complete explicit-detail maximum:

**12 feature HTTP requests**

This is a hard feature-network cap.

Session/setup requests must be classified separately in tests. The combined regression test must use one shared recording transport and prove that the feature path performs no more than twelve requests.

No Environment pagination beyond page 1 is allowed.

## Trigger Conditions

Environment loading is attempted only when all of the following are true:

1. Workflow Jobs loaded successfully;
2. Delivery correlation produced a proven base execution;
3. exact-SHA Deployment loading completed successfully;
4. at least one bounded Deployment evidence item remains eligible for presentation;
5. repository Actions capability is not definitively unavailable.

If any condition fails, Environment network traffic is zero.

Environment loading is still best effort. It never becomes required for Activity detail.

## Capability Gating

The Environment list endpoint uses repository **Actions: read** permission for fine-grained tokens.

SchneeBar already evaluates repository Actions capability.

Runtime behavior:

- `.available`: Environment enrichment may execute;
- `.unavailable`: skip Environment network calls;
- `.unknown`: allow the explicit user-triggered detail request.

This follows the existing capability principle:

> definitive unavailability blocks; uncertainty remains requestable for an explicit user action.

For a public repository with missing explicit Actions permission evidence, existing capability evaluation may produce `.unknown`; this remains requestable because GitHub allows public Environment resources to be read without the fine-grained permission.

No new `GitHubCapability` enum case is introduced.

## Environment REST Client

Add `GitHubEnvironmentClient` in `SchneeBarGitHub`.

Suggested normalized public model:

```swift
public enum GitHubEnvironmentBranchPolicy: Equatable, Sendable {
    case allBranches
    case protectedBranches
    case customBranches
    case unknown
}

public struct GitHubEnvironmentProtection: Equatable, Sendable {
    public let waitTimerMinutes: Int?
    public let requiredReviewerCount: Int?
    public let preventsSelfReview: Bool?
    public let branchPolicy: GitHubEnvironmentBranchPolicy
}

public struct GitHubEnvironment: Equatable, Sendable {
    public let id: Int64
    public let name: String
    public let protection: GitHubEnvironmentProtection
    public let createdAt: Date?
    public let updatedAt: Date?
}

public struct GitHubEnvironmentCatalog: Equatable, Sendable {
    public let totalCount: Int
    public let environments: [GitHubEnvironment]
    public let isTruncated: Bool
}
```

Client surface:

```swift
public struct GitHubEnvironmentClient: Sendable {
    public init(
        transport: any GitHubHTTPTransport = URLSessionGitHubHTTPTransport()
    )

    public func environments(
        repository: GitHubRepositoryAccess,
        connection: GitHubConnection,
        credential: GitHubCredential,
        limit: Int = 100
    ) async throws -> GitHubEnvironmentCatalog
}
```

Request:

```text
GET /repos/{owner}/{repo}/environments?per_page=100&page=1
```

Rules:

- `limit` is clamped to `1...100`;
- page is always exactly `1`;
- `total_count` must be non-negative;
- `total_count < environments.count` is invalid;
- `isTruncated = totalCount > environments.count`;
- invalid Environment IDs/names fail the client response rather than being partially trusted;
- GitHub.com/GHE.com API-version handling follows existing REST clients;
- GHES uses the existing explicit/no-version policy;
- provider `url` and `html_url` values are ignored and never enter the normalized model.

## DTO Normalization

Provider DTOs stay private to `GitHubEnvironmentClient`.

The client extracts only data needed by this slice.

### Wait timer

From a protection rule where:

```json
{
  "type": "wait_timer",
  "wait_timer": 30
}
```

Normalization:

- accept a non-negative integer;
- when multiple wait-timer rules are returned unexpectedly, treat the payload as invalid rather than choosing one.

### Required reviewers

From a protection rule where:

```json
{
  "type": "required_reviewers",
  "prevent_self_review": true,
  "reviewers": [...]
}
```

Normalization retains only:

- reviewer count;
- `prevent_self_review`.

Reviewer login, team name, avatar, URLs, and IDs are intentionally discarded.

When multiple required-reviewer rules are returned unexpectedly, treat the payload as invalid.

### Branch policy

Prefer the structured `deployment_branch_policy` field.

The DTO decoder must preserve whether the key was present so an older/partial payload cannot be mistaken for an explicit `null`.

- key present with `null` -> `.allBranches`;
- key present with `protected_branches == true && custom_branch_policies == false` -> `.protectedBranches`;
- key present with `protected_branches == false && custom_branch_policies == true` -> `.customBranches`;
- key missing -> `.unknown`;
- contradictory/partial object -> `.unknown`.

The presence of a generic `branch_policy` item in `protection_rules` does not trigger an additional network request.

Custom pattern values are not fetched.

### Unknown protection-rule types

Unknown rule types are ignored for this slice.

They must not be summarized as absent protection.

This is important because custom deployment protection rules are a separate API family and future built-in rule types may appear.

## Provider URL Handling

This slice does not need an Environment URL.

Provider `url` and `html_url` fields from the Environment payload are ignored during normalization and are not retained in memory beyond DTO decoding.

The existing user-visible Deployment destination URL remains authoritative.

Environment enrichment never replaces a Deployment's sanitized `environmentURL` or `logURL`, and no automatic navigation occurs.

## Environment Loading Service

Add a focused service in `SchneeBarGitHub`:

```swift
public protocol GitHubEnvironmentCatalogLoading: Sendable {
    func environmentCatalog(
        connection: GitHubConnection,
        identity: GitHubAccountIdentity,
        clientID: String?,
        repository: GitHubRepositoryAccess
    ) async throws -> GitHubEnvironmentCatalog
}

public struct GitHubEnvironmentCatalogService:
    GitHubEnvironmentCatalogLoading,
    Sendable
{
    public init(
        sessionCoordinator: GitHubConnectionSessionCoordinator,
        environmentClient: GitHubEnvironmentClient = .init()
    )
}
```

Rules:

- authorize once;
- perform exactly one Environment list feature request;
- do not paginate;
- preserve `CancellationError`;
- do not convert technical failure into an empty catalog inside the service.

Failure isolation belongs to App composition so tests can prove that a technical failure preserves existing Deployment events.

## Matching Rule

Environment data is presentation metadata only.

A Deployment remains eligible because of exact-SHA correlation from PR #51.

Environment matching is performed using the Environment name attached to the already-eligible Deployment evidence:

1. prefer non-empty latest Deployment Status environment;
2. otherwise use non-empty Deployment environment;
3. trim whitespace;
4. compare case-insensitively.

GitHub Environment names are case-insensitive and unique within a repository.

Rules:

- an empty Deployment environment never matches;
- an unmatched Deployment stays unchanged;
- more than one normalized catalog match is treated as ambiguous and stays unchanged;
- branch/ref similarity is irrelevant;
- timestamp similarity is irrelevant;
- Environment HTML URL similarity is irrelevant;
- Environment ID is not inferred from Deployment payloads.

The Environment catalog can enrich an eligible Deployment event; it can never create one.

## Provider Builder Integration

Keep `GitHubDeliveryTimelineBuilder` pure.

Do not move network access into the builder.

Recommended shape:

```swift
public func appendDeployments(
    to timeline: DeliveryTimelineSnapshot,
    evidence: GitHubDeploymentTimelineEvidence,
    environmentCatalog: GitHubEnvironmentCatalog? = nil
) -> DeliveryTimelineSnapshot
```

The default preserves source compatibility for existing callers/tests while the App path can pass the optional catalog.

Alternative acceptable implementation:

```swift
public func enrichDeployments(
    in timeline: DeliveryTimelineSnapshot,
    deploymentEvidence: GitHubDeploymentTimelineEvidence,
    environmentCatalog: GitHubEnvironmentCatalog
) -> DeliveryTimelineSnapshot
```

Choose one API during implementation planning, but the following behavior is mandatory:

- existing PR/merge/execution event order is unchanged;
- existing Deployment ordering is unchanged;
- Environment metadata changes only Deployment event detail text;
- Environment metadata never changes timeline correlation confidence;
- Environment metadata never changes Deployment state;
- Environment metadata never changes Job aggregate state;
- no matched metadata means byte-for-byte-equivalent timeline semantics.

## Presentation

No new Core type is required.

Reuse the existing `DeliveryTimelineEvent.detail` field.

Current Deployment detail:

```text
Succeeded · Production
```

Protected Environment example:

```text
Succeeded · Production · 2 reviewers · 30m wait · Custom branches
```

Another example:

```text
Running · 1 reviewer · No self-review · Protected branches
```

Presentation ordering is deterministic:

1. Deployment status;
2. existing Production / Transient context;
3. required reviewer count;
4. wait timer;
5. `No self-review` only when explicitly true;
6. branch-policy label.

Labels:

- one reviewer -> `1 reviewer`;
- multiple reviewers -> `N reviewers`;
- positive wait timer -> `Nm wait`, or a compact hours/days form when exactly divisible;
- a zero-minute wait timer produces no label;
- reviewer count zero produces no reviewer label;
- protected-branch mode -> `Protected branches`;
- custom-branch mode -> `Custom branches`;
- all-branches mode -> no branch-policy label;
- unknown branch-policy mode -> no branch-policy label.

Do **not** show:

- reviewer names;
- team names;
- rule IDs;
- Environment IDs;
- raw JSON;
- raw SHA;
- Environment API URLs;
- custom-rule app identity.

If the Environment is matched but no recognized built-in protection metadata is available, keep the original Deployment detail unchanged. Do not claim "No protection", because custom protection rules are outside this slice.

The current 340-point detail width remains unchanged. Existing two-line truncation behavior remains authoritative.

## App Composition

Extend the existing detail composition after Deployment evidence succeeds.

Pseudo-flow:

```swift
let deploymentEvidence = try await deploymentTimelineLoader.deploymentEvidence(...)

var environmentCatalog: GitHubEnvironmentCatalog?
if !deploymentEvidence.deployments.isEmpty,
   actionsAccess != .unavailable
{
    do {
        environmentCatalog = try await environmentCatalogLoader.environmentCatalog(...)
    } catch let cancellation as CancellationError {
        throw cancellation
    } catch {
        environmentCatalog = nil
    }
}

deliveryTimeline = timelineBuilder.appendDeployments(
    to: deliveryTimeline,
    evidence: deploymentEvidence,
    environmentCatalog: environmentCatalog
)
```

Important ordering:

- do not request Environment data before exact-SHA Deployment evidence exists;
- an Environment failure must not suppress Deployment events;
- cancellation propagates;
- Environment enrichment remains absent from normal Activity polling.

## Failure Isolation

```text
Jobs failure
  -> detail fails as today

Delivery correlation failure
  -> existing timeline behavior

Deployment capability unavailable
  -> no Deployment request
  -> no Environment request

Deployment technical failure
  -> existing PR/merge/execution timeline preserved
  -> no Environment request

Deployment success with zero deployments
  -> existing timeline preserved
  -> no Environment request

Deployment success with deployments
  + Actions capability unavailable
  -> Deployment events preserved
  -> no Environment request

Deployment success with deployments
  + Environment technical failure
  -> Deployment events preserved unchanged

Deployment success with deployments
  + Environment not present on page 1
  -> that Deployment event preserved unchanged
```

Raw Environment errors never enter Core/UI state.

## Pagination and Truncation

This slice requests:

`per_page=100&page=1`

If `total_count > environments.count`, the catalog is marked truncated.

Truncation rules:

- matched page-1 Environments can still enrich their corresponding Deployment events;
- unmatched Deployment names remain unenriched;
- no second page is fetched;
- the UI does not claim an unmatched Environment has no protection;
- no warning is shown solely because the repository has more than one hundred Environments.

Standalone Environment browsing can introduce proper pagination later.

## Cancellation

Environment enrichment is one sequential request.

Call `Task.checkCancellation()` before starting the Environment request.

If cancellation occurs:

- propagate `CancellationError`;
- do not append stale Environment metadata;
- preserve the existing selected-item identity guard in App runtime.

## Security and Privacy

- read-only endpoint only;
- no Administration permission;
- no secret/variable endpoint;
- no Environment write endpoint;
- no deployment approval endpoint;
- reviewer identities are discarded during DTO normalization;
- private Environment names are only held in memory for the open detail path;
- no persistence is added;
- fixtures use synthetic Environment names and `example.test` URLs only;
- provider Environment URLs are discarded rather than retained;
- no third-party action changes;
- no `pull_request_target`;
- no raw provider DTO reaches Core or SwiftUI.

## Enterprise Behavior

Use the existing endpoint resolver and REST API-version policy.

For GitHub.com and GHE.com, use the existing current-version behavior.

For GHES:

- explicit supported server API version behavior remains unchanged;
- unknown/untested server capability remains requestable only when the existing Actions capability state is not definitively unavailable;
- a 404/unsupported response is treated as best-effort Environment enrichment failure;
- existing Deployment events remain visible.

This slice does not introduce a new GHES version matrix.

## Visual Coverage

Add deterministic Light/Dark scenarios that extend PR #51 fixtures.

Required visual states:

1. production Deployment succeeded with reviewers + wait timer + custom branch mode;
2. staging Deployment running with protected-branch mode;
3. Deployment event with Actions capability unavailable and therefore no Environment metadata;
4. Environment request failure fallback represented by the unchanged Deployment event;
5. repository catalog truncated with a page-1 matched Environment;
6. multiple Deployment events where only some Environment names match.

All fixture URLs use `example.test`.

No reviewer login/team identity appears in fixture output.

## Testing Strategy

Development remains TDD.

### GitHubEnvironmentClient

Test:

- exact `/repos/{owner}/{repo}/environments` path;
- `per_page=100&page=1`;
- limit clamping;
- GitHub.com/GHE.com API-version behavior;
- GHES explicit/no-version behavior;
- `total_count` decoding;
- truncation detection;
- wait-timer normalization;
- reviewer-count normalization;
- reviewer identity discard;
- `prevent_self_review`;
- branch-policy normalization;
- `null` branch policy;
- unknown protection-rule tolerance;
- duplicate built-in rule rejection;
- provider URL fields are discarded;
- missing versus explicit-null `deployment_branch_policy`;
- invalid repository/credential/response handling.

### GitHubEnvironmentCatalogService

Test:

- one authorization path;
- exactly one feature request;
- cancellation before request;
- client errors propagate to App composition.

### Builder

Test:

- case-insensitive exact Environment-name match;
- Status Environment preferred over Deployment Environment;
- empty names never match;
- ambiguous normalized matches do not enrich;
- matched built-in metadata appends in deterministic order;
- no recognized built-in metadata leaves original detail unchanged;
- unknown protection rules do not produce a "no protection" claim;
- timeline status/confidence/state/order stay unchanged;
- Deployment destination URL priority stays unchanged.

### App Runtime

Test:

- zero Environment calls when no correlated base run;
- zero Environment calls when Deployment capability blocks Deployment loading;
- zero Environment calls after Deployment technical failure;
- zero Environment calls for empty Deployment evidence;
- zero Environment calls when Actions capability is unavailable;
- Environment request allowed when Actions capability is unknown;
- Environment technical failure preserves Deployment events;
- Environment success enriches existing Deployment events;
- cancellation propagates.

### Combined Request Budget

Use one shared recording transport.

Force the existing path to consume its full budget:

- Delivery correlation: 7;
- Deployment enrichment: 4;
- Environment list: 1.

Assert:

```swift
#expect(featureRequests.count == 12)
#expect(environmentRequests.count == 1)
```

Classify session/setup requests separately.

### Visual Regression

Render all required Environment scenarios in Light and Dark appearances.

## Expected Production Files

Likely changes after written-spec and implementation-plan approval:

- create `Sources/SchneeBarGitHub/GitHubEnvironmentClient.swift`;
- create `Sources/SchneeBarGitHub/GitHubEnvironmentCatalogService.swift`;
- modify `Sources/SchneeBarGitHubActivityProvider/GitHubDeliveryTimelineBuilder.swift`;
- modify `Sources/SchneeBarApp/GitHubConnectionsRuntimeModel+ActivityDetail.swift`;
- modify `Sources/SchneeBarApp/SchneeBarApp.swift`;
- extend `Sources/SchneeBarPreviewSupport/ActivityDetailFixtures.swift`;
- extend Visual Harness and Snapshot CLI;
- update `docs/DEVELOPMENT_PLAN.md`.

Likely tests:

- create `Tests/SchneeBarGitHubTests/GitHubEnvironmentClientTests.swift`;
- create `Tests/SchneeBarGitHubTests/GitHubEnvironmentCatalogServiceTests.swift`;
- extend the complete Delivery request-budget regression;
- extend `GitHubDeliveryTimelineBuilderTests`;
- extend `GitHubConnectionsRuntimeModelActivityDetailTests`;
- extend deterministic visual regression coverage.

No Core model change is expected.

## Acceptance Criteria

1. Environment loading happens only after eligible exact-SHA Deployment evidence exists.
2. Background Developer Activity polling performs zero Environment requests.
3. Environment enrichment adds at most one feature HTTP request.
4. The complete explicit-detail Delivery path performs at most twelve feature HTTP requests.
5. Environment metadata never establishes Deployment correlation.
6. Environment matching is case-insensitive exact-name matching only.
7. Environment failure never hides Jobs, PR/merge/execution events, or Deployment events.
8. Actions capability unavailable causes zero Environment requests.
9. Actions capability unknown remains requestable for explicit detail.
10. Page-1 truncation never triggers pagination.
11. Unmatched/truncated Environment data never produces a false "no protection" statement.
12. Reviewer identities are discarded and never displayed.
13. Custom deployment protection rules are not queried.
14. Custom deployment branch-policy patterns are not queried.
15. No Environment write, secret, variable, approval, or administration endpoint is called.
16. GitHub Environment DTOs do not leak into Core or SwiftUI.
17. Existing Deployment state, URL, event order, and correlation confidence remain authoritative.
18. Light/Dark visual regression covers protected and fallback states.
19. Final implementation head must pass CI, Visual Regression, and CodeQL before integration.

## Deferred Follow-up

- paginated Environment inventory;
- standalone Environment browser;
- exact custom deployment branch-policy patterns;
- custom deployment protection-rule integrations;
- required reviewer identity display if a future privacy review explicitly approves it;
- pending deployment approval actions;
- Environment secrets/variables;
- persisted Environment history;
- recovery notifications;
- repository default-branch discovery;
- standalone Delivery history/navigation.

## Self-review Checklist

Before implementation planning:

- no unresolved placeholders;
- no hidden custom-rule request;
- no hidden branch-policy pattern request;
- no background Environment polling;
- complete feature request cap is twelve;
- capability gating uses existing Actions capability;
- exact-SHA Deployment remains the only deployment correlation authority;
- Environment name matching is presentation-only;
- Environment failure preserves existing Deployment events;
- reviewer identities are discarded;
- page-1 truncation behavior is explicit;
- no Core schema change is required;
- visual and security behavior are explicit.

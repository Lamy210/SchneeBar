# GitHub Capability Contract Design

Status: Draft for review
Date: 2026-09-15
Base: `main@68321042`

## Context

SchneeBar already has a `GitHubCapability` enum, GitHub.com / GHE.com / GHES endpoint resolution, GHES discovery and compatibility policy, authenticated account/session restoration, installation inventory, repository access inventory, and GitHub Actions activity polling.

What is missing is an explicit capability contract that answers three different questions without conflating them:

1. Does the connected GitHub platform plausibly support the feature?
2. Does the current GitHub App installation expose the permission required for the feature?
3. Is the feature effectively usable for a particular repository in the current session?

A single boolean `Set<GitHubCapability>` cannot represent those distinctions. In particular, treating every missing installation permission as "unsupported" would incorrectly conflate platform compatibility, GitHub App permission configuration, user/repository access, and public-resource fallback behavior.

The capability contract therefore becomes session-scoped, evidence-based, and repository-aware.

## Goals

- Keep provider-specific capability logic inside `SchneeBarGitHub`.
- Preserve the existing `GitHubCapability` identifiers as the stable vocabulary.
- Evaluate capabilities from already-fetched connection and installation inventory where possible.
- Distinguish definite unavailability from incomplete evidence.
- Avoid extra REST probes during normal connection refresh.
- Allow GitHub Activity polling to skip repositories that are definitively unable to provide Actions data.
- Keep raw bearer credentials and raw installation permission dictionaries out of App/UI state.
- Remain conservative for untested GHES versions: uncertainty must not become a false unsupported result.
- Preserve public-repository fallback opportunities when GitHub documents that an endpoint can work without the fine-grained permission for public resources.

## Non-goals

- A new capability settings UI in this change.
- Dynamically probing every GitHub REST endpoint to discover capabilities.
- Persisting capability results in `GitHubConnectionProfile`.
- Automatically modifying GitHub App permissions.
- Implementing review requests, Checks, deployments, environments, workflow writes, merge queue, releases, or security alerts themselves.
- Treating GitHub's compatibility test range as a hard product-support cutoff.

## Verified GitHub permission constraints

The initial read-capability policies are based on current GitHub REST documentation as of 2026-09-15:

| SchneeBar capability | Initial evidence requirement | Notes |
| --- | --- | --- |
| `actions` | `actions` repository permission at `read` or `write` | Workflow run listing requires Actions read. |
| `pullRequests` | `pull_requests` repository permission at `read` or `write` | List PRs and review-request APIs require Pull requests read. Some individual PR endpoints can also accept Contents read, but the SchneeBar feature contract targets the broader PR/review-request surface. |
| `checks` | `checks` repository permission at `read` or `write` | Reading check runs/suites requires Checks read. |
| `deployments` | `deployments` repository permission at `read` or `write` | Deployment listing/status requires Deployments read. Environment APIs additionally use Actions read; environment availability will therefore compose `deployments` and `actions` when that Phase 4 feature is implemented. |

`releases`, `mergeQueue`, `securityAlerts`, and `workflowWrite` remain `unknown` in the first evaluator until their exact product semantics are implemented and verified.

GitHub documents that several read endpoints can be used without the listed fine-grained permission when only public resources are requested. Therefore, a missing installation permission is definitive evidence for a private repository but not always for a public repository.

GitHub also exposes the `X-Accepted-GitHub-Permissions` response header. That can become a future evidence source, but v1 does not add probe requests or adaptive header learning.

References:

- https://docs.github.com/en/rest/actions/workflow-runs
- https://docs.github.com/en/rest/pulls/pulls
- https://docs.github.com/en/rest/pulls/review-requests
- https://docs.github.com/en/rest/checks/runs
- https://docs.github.com/en/rest/deployments/deployments
- https://docs.github.com/en/rest/deployments/environments
- https://docs.github.com/en/rest/using-the-rest-api/troubleshooting-the-rest-api

## Architecture decision

Use an evidence-based assessment model. Capability results are computed when a `GitHubConnectionSession` is established or restored and are kept in memory alongside the already-fetched access inventory.

The flow becomes:

```text
GitHubConnection
      +
GitHubAccessInventory
      |
      v
GitHubCapabilityEvaluator
      |
      v
GitHubConnectionCapabilityAssessment
      |
      +--> GitHubConnectionSession
      |        |
      |        v
      |    App runtime cache
      |
      +--> GitHubActivityProvider preflight gate
```

No AppKit, SwiftUI, or generic `SchneeBarCore` type is introduced into the GitHub capability domain.

## Capability model

### Repository-level assessment

The primary unit is a repository because the same connection can expose repositories with different visibility and installation evidence.

Conceptual model:

```swift
public struct GitHubRepositoryCapabilityAssessment: Equatable, Sendable {
    public let repositoryID: Int64
    public let states: [GitHubCapability: GitHubCapabilityState]
}

public enum GitHubCapabilityState: Equatable, Sendable {
    case available
    case unavailable(GitHubCapabilityBlocker)
    case unknown(GitHubCapabilityUncertainty)
}
```

`GitHubCapabilityState` is intentionally not persisted. It represents current-session evidence and may change when installation permissions, repository visibility, credentials, or server compatibility change.

### Normalized blockers

Blockers are provider-domain values, not raw GitHub permission strings exposed to UI:

```swift
public enum GitHubCapabilityBlocker: Equatable, Sendable {
    case missingPermission
    case installationSuspended
    case installationForbidden
    case installationNotFound
    case installationUnavailable
}
```

Repositories are currently only returned for `.available` installation inventory entries, so installation-level failures cannot always be attributed to a specific repository ID. The connection assessment therefore also carries normalized installation issues separately instead of inventing repository associations.

### Normalized uncertainty

```swift
public enum GitHubCapabilityUncertainty: Equatable, Sendable {
    case publicRepositoryPermissionNotProven
    case untestedEnterpriseVersion
    case unknownEnterpriseVersion
    case unmappedCapability
    case unrecognizedPermissionLevel
    case conflictingEvidence
}
```

Unknown means "do not claim support or lack of support from current evidence." Consumers may still attempt a read request.

### Connection-level assessment

```swift
public struct GitHubConnectionCapabilityAssessment: Equatable, Sendable {
    public let repositories: [Int64: GitHubRepositoryCapabilityAssessment]
    public let installationIssues: [GitHubInstallationCapabilityIssue]
}
```

Connection-wide presentation should be derived from repository states instead of stored as another source of truth. A future UI can compute coverage for a capability:

- all considered repositories available -> `available`
- at least one available and at least one unavailable/unknown -> `partial`
- all considered repositories unavailable -> `unavailable`
- no available repositories and at least one unknown -> `unknown`
- no repository evidence -> `unknown`

## Platform-support evidence

Platform evidence is intentionally conservative.

### GitHub.com and GHE.com

For the four initial read capabilities (`actions`, `pullRequests`, `checks`, `deployments`), current hosted GitHub is treated as platform-supported because the corresponding current REST APIs are documented.

### GitHub Enterprise Server

Reuse `GitHubEnterpriseCompatibilityPolicy`:

- tested GHES version -> platform evidence is supported for the four initial read capabilities
- older/newer untested GHES version -> platform evidence is unknown
- missing/unparseable server version -> platform evidence is unknown

An untested GHES version must never be converted directly into `unavailable`. If the required permission is present but platform support is uncertain, the effective state remains `unknown` and consumers are allowed to try the request.

No capability-specific GHES minimum-version matrix is added in v1. Such a matrix should only be added when a concrete endpoint is known to be absent on a supported server generation.

## Permission evidence

Installation permissions are already present in `GitHubInstallation.permissions` as `[String: String]` from `/user/installations`.

The evaluator normalizes values case-insensitively:

- `read` -> satisfies a read capability
- `write` -> satisfies a read capability
- missing key -> no permission evidence
- any unrecognized non-empty value -> unknown evidence

Evaluation rules for the four mapped read capabilities:

1. Platform supported + required read permission present -> `available`.
2. Platform unknown + required read permission present -> `unknown(platform...)`.
3. Required permission missing on a private repository -> `unavailable(.missingPermission)`.
4. Required permission missing on a public repository -> `unknown(.publicRepositoryPermissionNotProven)` because GitHub documents public-resource access without that fine-grained permission for these endpoints.
5. Unrecognized permission level -> `unknown(.unrecognizedPermissionLevel)`.
6. Capability without a v1 permission policy -> `unknown(.unmappedCapability)`.

Definite blockers take precedence over platform uncertainty. For example, a private repository with no required permission remains unavailable even when the GHES version is untested.

## Duplicate and conflicting inventory evidence

Repository IDs are the identity boundary. The evaluator must not silently pick one installation when the same repository ID appears with conflicting evidence.

If duplicate repository entries produce identical capability states, they collapse deterministically.

If duplicate entries produce conflicting capability states, the repository capability becomes `unknown(.conflictingEvidence)` for the conflicting capability. This is safer than choosing the most permissive or most restrictive installation without knowing which evidence GitHub will apply to the user access token.

## Session integration

`GitHubConnectionSession` gains a capability assessment:

```swift
public let capabilities: GitHubConnectionCapabilityAssessment
```

`GitHubConnectionSessionCoordinator.establish` and `.restore` compute it after access inventory is loaded:

```text
load account -> load inventory -> evaluate capabilities -> return session
```

The evaluator performs no network I/O.

The App runtime caches capability assessments by connection ID alongside `inventoryByConnectionID` and clears both on disable, disconnect, or authentication invalidation. Capability results are not written to the profile store.

## GitHub Activity integration

Actions polling is the first production consumer.

`GitHubActivityProvider.load` receives the connection capability assessment. Repository scheduling applies this rule before a workflow-run request:

- `actions == .unavailable` -> do not call `GitHubWorkflowRunLoading`
- `actions == .available` -> use the existing poll path
- `actions == .unknown` -> use the existing poll path; runtime HTTP behavior remains authoritative
- missing repository assessment -> use the existing poll path for backward-safe behavior

This prevents known-useless private-repository requests while preserving public-resource and untested-GHES fallback behavior.

### Activity result accounting

Preflight blocking must not corrupt the existing request-budget semantics.

`GitHubActivityLoadResult` therefore keeps:

- `attemptedRepositoryCount`: actual network-backed repository attempts
- `successfulRepositoryCount`: successful repository loads

and adds:

- `blockedRepositoryCount`: repositories rejected by definitive capability evidence
- `consideredRepositoryCount`: computed `attemptedRepositoryCount + blockedRepositoryCount`

A preflight-blocked repository produces a normalized `GitHubRepositoryActivityFailureReason.capabilityUnavailable` failure but does not increment `attemptedRepositoryCount`.

App-level failure aggregation uses `consideredRepositoryCount` when deciding whether all selected work failed. `capabilityUnavailable` contributes to an unavailable connection state, not an authentication-required or transient-network state.

This keeps "network request attempted" semantically accurate while still surfacing a connection that has no usable Actions capability.

## Error and recovery behavior

- Capability evaluation itself is pure and non-throwing for valid normalized inventory.
- Missing/unknown evidence yields `unknown`, not an exception.
- Authentication failures remain session errors and are not capability states.
- Network failures during inventory refresh remain connection runtime states and do not overwrite the last capability assessment with fabricated values.
- A successful later refresh recomputes capability assessment from fresh inventory and naturally recovers from permission changes.
- A capability assessment must never contain tokens, request URLs containing credentials, or private error payloads.

## Existing type migration

`GitHubCapability` remains the capability vocabulary.

The existing unused `GitHubCapabilitySet` boolean wrapper is removed or replaced by the richer assessment model. It currently has no repository consumers, so retaining a parallel boolean capability abstraction would create contradictory sources of truth.

Source-file placement is an implementation detail; the preferred structure is a focused `GitHubCapabilityAssessment.swift` rather than expanding `GitHubConnection.swift` further.

## Tests

Implementation must follow TDD. The first failing tests should cover the pure evaluator before session or Activity wiring.

### `SchneeBarGitHubTests`

1. hosted GitHub + `actions=read` -> Actions available
2. hosted GitHub + `actions=write` -> Actions available
3. private repository + missing Actions permission -> unavailable / missing permission
4. public repository + missing Actions permission -> unknown / public permission not proven
5. unrecognized permission value -> unknown
6. PR / Checks / Deployments mappings use their own permission keys
7. unmapped capabilities remain unknown
8. tested GHES + permission -> available
9. untested/newer GHES + permission -> unknown, never unavailable solely from version
10. missing GHES version + permission -> unknown
11. duplicate identical evidence collapses deterministically
12. duplicate conflicting evidence -> unknown / conflicting evidence
13. suspended/forbidden/not-found/unavailable installations appear as normalized installation issues without invented repository IDs

### Session coordinator tests

1. `establish` returns the assessment computed from its fresh inventory
2. `restore` returns a newly computed assessment after inventory changes
3. credentials are not exposed through capability types

### `SchneeBarGitHubActivityProviderTests`

1. Actions unavailable -> workflow loader is not called
2. Actions unavailable -> blocked count increments and capability failure is returned
3. Actions unknown -> workflow loader is still called
4. Actions available -> existing poll behavior is unchanged
5. missing assessment -> existing poll behavior is unchanged
6. request budget counts only actual network attempts
7. hot/cold scheduling remains deterministic among eligible repositories

### App runtime tests / existing coverage

Where direct App-layer unit tests are impractical, keep App changes thin and verify compilation plus existing CI/Visual coverage. Provider-domain behavior must remain fully unit-tested outside AppKit/SwiftUI.

## Planned implementation slices

The implementation plan should keep the change reviewable in this order:

1. Pure capability models + evaluator + RED/GREEN unit tests.
2. Session coordinator integration + tests.
3. App runtime capability cache with no presentation expansion.
4. Activity preflight gating + result accounting + tests.
5. Full CI / Visual Regression / CodeQL verification.

No endpoint probe client or capability-specific UI is introduced in these slices.

## Acceptance criteria

The capability contract is complete when:

- capability assessment is computed from connection + current inventory without extra network requests
- private repositories with definitively missing required permissions are marked unavailable
- public repositories with missing permission evidence remain unknown rather than falsely unavailable
- untested/unknown GHES versions do not cause false unsupported results
- Actions polling skips only definitively unavailable repositories
- unknown capability states are still allowed to attempt normal read requests
- activity accounting distinguishes network attempts from capability-blocked repositories
- raw installation permission dictionaries do not reach App/UI presentation models
- capability results are session-scoped and recomputed on successful refresh
- unit tests cover the evaluator and Activity gating rules
- CI, Visual Regression, and CodeQL pass on the final implementation head

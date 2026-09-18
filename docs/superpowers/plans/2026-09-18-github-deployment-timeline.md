# GitHub Deployment Timeline Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Extend the existing evidence-backed Workflow Delivery Timeline with exact-SHA GitHub Deployment events while preserving current Jobs/timeline behavior, bounded request budgets, and provider isolation.

**Architecture:** Keep deployment REST access and credential orchestration in `SchneeBarGitHub`, keep GitHub-to-Core mapping in `SchneeBarGitHubActivityProvider`, and keep `SchneeBarCore` provider-neutral. The existing Delivery correlation remains authoritative; deployment enrichment only starts after a proven correlated base run and uses that run's exact SHA.

**Tech Stack:** Swift 6.3, SwiftUI/AppKit, Swift Testing, Tuist 4.203.1, GitHub REST API, GitHub Actions CI / Visual Regression / CodeQL.

**Spec:** `docs/superpowers/specs/2026-09-18-github-deployment-timeline-design.md`

## Global Constraints

- macOS production target remains 15.0.
- Xcode 26.6 / Swift 6.3 remain the stable baseline.
- No GitHub DTO may leak into `SchneeBarCore` or SwiftUI.
- No Deployment request may be added to normal Developer Activity polling.
- A Deployment is eligible only when its normalized SHA exactly equals the already-proven correlated base execution `headSHA`.
- Environment name, branch/ref text, timestamps, workflow names, PR numbers alone, and status URLs never establish Deployment correlation.
- Environment inventory/protection APIs are out of scope for this slice.
- Deployment enrichment performs at most 4 HTTP requests: 1 exact-SHA deployment list + at most 3 latest-status requests.
- The complete explicit-detail Delivery path performs at most 11 HTTP requests.
- Deployment list and status lookups are first-page-only in this slice.
- Deployment technical failure must preserve Jobs and the already-correlated PR/merge/execution timeline.
- Missing Deployment capability skips enrichment; unknown capability remains explicitly requestable.
- External deployment URLs must be absolute HTTPS URLs, have a non-empty host, and contain no username/password.
- No raw SHA is shown in the UI.
- The PR base branch must not be labeled as the repository default branch without explicit metadata.
- Production changes follow TDD: write a failing test, observe the intended failure, implement the minimum change, then run the focused regression target.

---

### Task 1: Extend the provider-neutral Delivery Timeline event contract

**Files:**
- Modify: `Sources/SchneeBarCore/DeliveryTimeline.swift`
- Modify: `Tests/SchneeBarCoreTests/DeliveryTimelineTests.swift`

**Interfaces:**
- Consumes: existing `DeliveryTimelineEventKind`.
- Produces: `DeliveryTimelineEventKind.deployment`.
- Does not introduce GitHub-specific types into Core.

- [ ] **Step 1: Write the failing Core test**

Add:

```swift
@Test
func deliveryTimelineSupportsDeploymentEventsWithoutReordering() {
    let events = [
        DeliveryTimelineEvent(
            id: "execution",
            kind: .execution,
            title: "Base branch · CI",
            state: .success
        ),
        DeliveryTimelineEvent(
            id: "deployment",
            kind: .deployment,
            title: "Deployment · production",
            state: .success
        ),
    ]

    let snapshot = DeliveryTimelineSnapshot(
        status: .correlated,
        confidence: .exact,
        events: events
    )

    #expect(snapshot.events.map(\.kind) == [.execution, .deployment])
}
```

- [ ] **Step 2: Verify RED**

Run:

```bash
mise exec -- tuist test SchneeBarCoreTests -- -skipMacroValidation CODE_SIGNING_ALLOWED=NO
```

Expected: compile failure because `DeliveryTimelineEventKind.deployment` does not exist.

- [ ] **Step 3: Implement the minimum Core change**

Change:

```swift
public enum DeliveryTimelineEventKind: String, Codable, CaseIterable, Sendable {
    case pullRequest
    case merge
    case execution
    case deployment
}
```

Do not add deployment status/environment/provider fields to Core.

- [ ] **Step 4: Verify GREEN**

Run the same Core test target. Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/SchneeBarCore/DeliveryTimeline.swift Tests/SchneeBarCoreTests/DeliveryTimelineTests.swift
git commit -m "feat: add deployment timeline event kind"
```

### Task 2: Add a bounded GitHub Deployment REST client

**Files:**
- Create: `Sources/SchneeBarGitHub/GitHubDeploymentClient.swift`
- Create: `Tests/SchneeBarGitHubTests/GitHubDeploymentClientTests.swift`

**Interfaces:**
- Consumes: `GitHubHTTPTransport`, `GitHubRepositoryAccess`, `GitHubConnection`, `GitHubCredential`, existing endpoint/version policy.
- Produces:

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

public enum GitHubDeploymentClientError: Error, Equatable, Sendable {
    case invalidCredential
    case invalidRepository
    case invalidSHA
    case invalidDeploymentID
    case invalidResponse
    case httpStatus(Int)
}

public struct GitHubDeploymentClient: Sendable {
    public init(transport: any GitHubHTTPTransport = URLSessionGitHubHTTPTransport())

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
}
```

- [ ] **Step 1: Write RED client tests for the Deployment list**

Use a recording `GitHubHTTPTransport` and assert:

```swift
#expect(request.httpMethod == "GET")
#expect(request.url?.path == "/repos/snow/app/deployments")
#expect(queryValue("sha", in: request) == "landed-sha")
#expect(queryValue("per_page", in: request) == "20")
#expect(queryValue("page", in: request) == "1")
```

Also prove:

- response deployment SHA must normalize to the requested SHA or fail with `.invalidResponse`;
- `limit` is clamped to `1...20`;
- empty/whitespace SHA throws `.invalidSHA`;
- empty credential throws `.invalidCredential`;
- invalid repository throws `.invalidRepository`;
- GitHub.com/GHE.com include the existing REST API version header;
- GHES follows the existing explicit/no-version behavior.

- [ ] **Step 2: Write RED status tests**

Assert the request:

```text
GET /repos/snow/app/deployments/901/statuses?per_page=1&page=1
```

Decode at least:

```json
{
  "id": 1001,
  "state": "success",
  "environment": "production",
  "description": "Deployed",
  "environment_url": "https://example.test/prod",
  "log_url": "https://example.test/logs/1001",
  "created_at": "2026-09-18T00:00:00Z",
  "updated_at": "2026-09-18T00:01:00Z"
}
```

Assert unknown state preservation:

```swift
#expect(status.state == .unknown("future_state"))
```

- [ ] **Step 3: Write RED URL sanitization tests**

The normalized status must retain:

```text
https://example.test/deployment/1
```

and drop all of:

```text
http://example.test/deployment/1
https://user:pass@example.test/deployment/1
https:///missing-host
relative/path
```

Representative assertion:

```swift
#expect(status.environmentURL == nil)
#expect(status.logURL == nil)
```

- [ ] **Step 4: Verify RED**

Run:

```bash
mise exec -- tuist test SchneeBarGitHubTests -- -skipMacroValidation CODE_SIGNING_ALLOWED=NO
```

Expected: compile failure because Deployment client/models do not exist.

- [ ] **Step 5: Implement the client**

Use private DTOs:

```swift
private struct DeploymentPayload: Decodable {
    let id: Int64
    let sha: String
    let environment: String
    let productionEnvironment: Bool?
    let transientEnvironment: Bool?
    let createdAt: Date?
    let updatedAt: Date?
}

private struct DeploymentStatusPayload: Decodable {
    let id: Int64
    let state: String
    let environment: String?
    let description: String?
    let environmentURL: String?
    let logURL: String?
    let createdAt: Date?
    let updatedAt: Date?
}
```

Configure decoding for GitHub snake_case and ISO-8601 dates. Normalize SHA with trimmed lowercase comparison but preserve a normalized lowercase SHA in the public model.

Use a URL helper equivalent to:

```swift
private func safeExternalURL(_ rawValue: String?) -> URL? {
    guard let rawValue,
          let url = URL(string: rawValue),
          url.scheme?.lowercased() == "https",
          let host = url.host,
          !host.isEmpty,
          url.user == nil,
          url.password == nil
    else {
        return nil
    }
    return url
}
```

Do not paginate. Deployment list is exactly page 1; status is exactly page 1 with `per_page=1`.

- [ ] **Step 6: Verify GREEN**

Run the GitHub test target. Expected: PASS, including existing GitHub clients.

- [ ] **Step 7: Commit**

```bash
git add Sources/SchneeBarGitHub/GitHubDeploymentClient.swift Tests/SchneeBarGitHubTests/GitHubDeploymentClientTests.swift
git commit -m "feat: add bounded GitHub deployment client"
```

### Task 3: Add demand-driven Deployment evidence loading with a four-request hard cap

**Files:**
- Create: `Sources/SchneeBarGitHub/GitHubDeploymentTimelineService.swift`
- Create: `Tests/SchneeBarGitHubTests/GitHubDeploymentTimelineServiceTests.swift`
- Create: `Tests/SchneeBarGitHubTests/GitHubDeliveryAndDeploymentRequestBudgetTests.swift`

**Interfaces:**
- Consumes: `GitHubConnectionSessionCoordinator`, `GitHubDeploymentClient`.
- Produces:

```swift
public struct GitHubDeploymentEvidence: Equatable, Sendable {
    public let deployment: GitHubDeployment
    public let latestStatus: GitHubDeploymentStatus?
}

public struct GitHubDeploymentTimelineEvidence: Equatable, Sendable {
    public let exactSHA: String
    public let deployments: [GitHubDeploymentEvidence]
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

public struct GitHubDeploymentTimelineService: GitHubDeploymentTimelineLoading, Sendable {
    public init(
        sessionCoordinator: GitHubConnectionSessionCoordinator,
        deploymentClient: GitHubDeploymentClient = .init()
    )
}
```

`exactSHA` is retained in the evidence so the pure builder can defensively reject a mismatched deployment model even if a future client/service regression occurs.

- [ ] **Step 1: Write RED service tests**

Use a routing transport plus credential-store counter and prove:

1. one credential authorization path;
2. deployment list request is made with only the exact provided SHA;
3. an empty deployment list performs exactly one HTTP request;
4. status requests are made for at most three deployments;
5. total enrichment HTTP requests never exceed four;
6. cancellation before/inside the status loop prevents later status calls.

- [ ] **Step 2: Lock deterministic ordering in RED tests**

Given:

```swift
[
    deployment(id: 1, production: false, transient: false, updatedAt: t4),
    deployment(id: 2, production: true,  transient: false, updatedAt: t4),
    deployment(id: 3, production: true,  transient: true,  updatedAt: t3),
    deployment(id: 4, production: true,  transient: false, updatedAt: t2),
]
```

expect status requests in order:

```swift
[2, 4, 3]
```

because ordering is:

1. production first;
2. non-transient first;
3. updatedAt descending;
4. createdAt descending;
5. deployment ID descending.

Known timestamps sort before missing timestamps at each date comparison. When both date fields tie or are absent, deployment ID is the final deterministic tie-breaker.

- [ ] **Step 3: Verify RED**

Run:

```bash
mise exec -- tuist test SchneeBarGitHubTests -- -skipMacroValidation CODE_SIGNING_ALLOWED=NO
```

Expected: compile failure because the service/evidence types do not exist.

- [ ] **Step 4: Implement the service**

Core loop shape:

```swift
let credential = try await sessionCoordinator.authorizedCredential(
    connection: connection,
    identity: identity,
    clientID: clientID
)

try Task.checkCancellation()
let deployments = try await deploymentClient.deployments(
    sha: exactSHA,
    repository: repository,
    connection: connection,
    credential: credential,
    limit: 20
)

var evidence: [GitHubDeploymentEvidence] = []
for deployment in orderedDeployments(deployments).prefix(3) {
    try Task.checkCancellation()
    let status = try await deploymentClient.latestStatus(
        deploymentID: deployment.id,
        repository: repository,
        connection: connection,
        credential: credential
    )
    evidence.append(
        GitHubDeploymentEvidence(
            deployment: deployment,
            latestStatus: status
        )
    )
}
```

Return normalized `exactSHA` and the bounded evidence list.

- [ ] **Step 5: Verify GREEN and the hard request cap**

Run the GitHub test target. Require assertions against the transport's actual recorded request count:

```swift
#expect(requests.count == 4)
```

Do not infer the budget from method-call counters.

- [ ] **Step 6: Add a combined eleven-request budget regression test**

In `GitHubDeliveryAndDeploymentRequestBudgetTests.swift`, construct the existing `GitHubDeliveryTimelineService` and new `GitHubDeploymentTimelineService` with clients that all share one routing/recording `GitHubHTTPTransport`. Feed the correlation service a fixture that consumes its full 7-request budget (exact run + PR + base list + four association requests), then call Deployment enrichment for the proven candidate SHA with three deployments.

Assert the feature requests recorded by that shared transport are exactly:

```swift
#expect(featureRequests.count == 11)
#expect(featureRequests.filter { $0.url?.path.contains("/deployments") == true }.count == 4)
```

Credential/session setup requests, if the fixture requires them, must be recorded separately and excluded by explicit path classification rather than by subtracting a magic number.

This test is the acceptance proof for the complete explicit-detail network ceiling.

- [ ] **Step 7: Verify the combined budget test GREEN**

Run:

```bash
mise exec -- tuist test SchneeBarGitHubTests -- -skipMacroValidation CODE_SIGNING_ALLOWED=NO
```

Expected: PASS with the full-path feature request count at or below 11.

- [ ] **Step 8: Commit**

```bash
git add Sources/SchneeBarGitHub/GitHubDeploymentTimelineService.swift Tests/SchneeBarGitHubTests/GitHubDeploymentTimelineServiceTests.swift Tests/SchneeBarGitHubTests/GitHubDeliveryAndDeploymentRequestBudgetTests.swift
git commit -m "feat: load bounded deployment timeline evidence"
```

### Task 4: Preserve correlation authority and append Deployment events in the provider layer

**Files:**
- Modify: `Sources/SchneeBarGitHubActivityProvider/GitHubDeliveryTimelineBuilder.swift`
- Modify: `Tests/SchneeBarGitHubActivityProviderTests/GitHubDeliveryTimelineBuilderTests.swift`

**Interfaces:**
- Consumes: existing `GitHubDeliveryTimelineEvidence`, existing `GitHubWorkflowExecutionCorrelator`, new `GitHubDeploymentTimelineEvidence`.
- Produces:

```swift
public struct GitHubDeliveryTimelineBuildResult: Equatable, Sendable {
    public let timeline: DeliveryTimelineSnapshot
    public let correlatedBaseRun: GitHubWorkflowRun?
}

public struct GitHubDeliveryTimelineBuilder: Sendable {
    public func buildResult(
        repositoryID: Int64,
        evidence: GitHubDeliveryTimelineEvidence
    ) -> GitHubDeliveryTimelineBuildResult

    public func build(
        repositoryID: Int64,
        evidence: GitHubDeliveryTimelineEvidence
    ) -> DeliveryTimelineSnapshot

    public func appendDeployments(
        to timeline: DeliveryTimelineSnapshot,
        evidence: GitHubDeploymentTimelineEvidence
    ) -> DeliveryTimelineSnapshot
}
```

`build(...)` remains source-compatible and delegates to `buildResult(...).timeline`.

- [ ] **Step 1: Write RED tests for correlated base-run exposure**

For the existing exact correlation fixture:

```swift
let result = GitHubDeliveryTimelineBuilder().buildResult(
    repositoryID: 42,
    evidence: evidence
)

#expect(result.timeline.status == .correlated)
#expect(result.correlatedBaseRun?.id == 801)
#expect(result.correlatedBaseRun?.headSHA == "landed-sha")
```

For unavailable correlation:

```swift
#expect(result.correlatedBaseRun == nil)
```

This prevents App from duplicating the correlator's candidate-selection logic.

- [ ] **Step 2: Write RED deployment append tests**

Create evidence:

```swift
GitHubDeploymentTimelineEvidence(
    exactSHA: "landed-sha",
    deployments: [
        GitHubDeploymentEvidence(
            deployment: deployment(
                id: 901,
                sha: "landed-sha",
                environment: "production",
                production: true
            ),
            latestStatus: status(
                state: .success,
                environment: "production"
            )
        ),
    ]
)
```

Assert:

```swift
#expect(snapshot.events.map(\.kind) == [
    .pullRequest, .merge, .execution, .deployment
])
#expect(snapshot.events.last?.title == "Deployment · production")
#expect(snapshot.events.last?.detail == "Succeeded · Production")
#expect(snapshot.events.last?.state == .success)
```

- [ ] **Step 3: Write RED defensive mismatch tests**

If `deployment.sha != evidence.exactSHA`, it must not appear:

```swift
#expect(snapshot.events.map(\.kind) == [
    .pullRequest, .merge, .execution
])
```

Also cover:

- latest status environment overrides deployment environment when non-empty;
- empty status environment falls back to deployment environment;
- both empty -> `Deployment · Unknown environment`;
- production context comes only from `isProductionEnvironment`;
- transient context comes only from `isTransientEnvironment`;
- no status -> neutral / `Status unavailable`;
- `.failure` and `.error` -> failed;
- `.inProgress` -> running;
- `.pending` / `.queued` -> waiting;
- `.inactive` / unknown -> neutral;
- destination URL priority is sanitized `environmentURL`, then sanitized `logURL`.

- [ ] **Step 4: Verify RED**

Run:

```bash
mise exec -- tuist test SchneeBarGitHubActivityProviderTests -- -skipMacroValidation CODE_SIGNING_ALLOWED=NO
```

Expected: compile failure because `GitHubDeliveryTimelineBuildResult` and `appendDeployments` do not exist.

- [ ] **Step 5: Refactor build into a single correlation authority**

When the correlator accepts a candidate, return both:

```swift
return GitHubDeliveryTimelineBuildResult(
    timeline: correlatedTimeline(...),
    correlatedBaseRun: candidate
)
```

For every unavailable path:

```swift
return GitHubDeliveryTimelineBuildResult(
    timeline: unavailable(),
    correlatedBaseRun: nil
)
```

Keep:

```swift
public func build(
    repositoryID: Int64,
    evidence: GitHubDeliveryTimelineEvidence
) -> DeliveryTimelineSnapshot {
    buildResult(repositoryID: repositoryID, evidence: evidence).timeline
}
```

- [ ] **Step 6: Implement pure Deployment append mapping**

Preserve original event order:

```swift
var events = timeline.events
events.append(contentsOf: deploymentEvents)
return DeliveryTimelineSnapshot(
    status: timeline.status,
    confidence: timeline.confidence,
    events: events
)
```

Do not downgrade correlation confidence/status because deployment evidence is empty.

- [ ] **Step 7: Verify GREEN**

Run the provider tests. Expected: all previous correlation tests and new deployment tests PASS.

- [ ] **Step 8: Commit**

```bash
git add Sources/SchneeBarGitHubActivityProvider/GitHubDeliveryTimelineBuilder.swift Tests/SchneeBarGitHubActivityProviderTests/GitHubDeliveryTimelineBuilderTests.swift
git commit -m "feat: append deployment evidence to delivery timeline"
```

### Task 5: Compose Deployment enrichment in Workflow detail with capability gating and failure isolation

**Files:**
- Modify: `Sources/SchneeBarApp/GitHubConnectionsRuntimeModel+ActivityDetail.swift`
- Modify: `Sources/SchneeBarApp/SchneeBarApp.swift`
- Modify: `Tests/SchneeBarAppTests/GitHubConnectionsRuntimeModelActivityDetailTests.swift`

**Interfaces:**
- Consumes: `GitHubDeploymentTimelineLoading`, `GitHubDeliveryTimelineBuilder.buildResult`, repository activity-access presentation.
- `loadActivityDetail` gains:

```swift
deploymentTimelineLoader: any GitHubDeploymentTimelineLoading
```

- AppDelegate owns one `GitHubDeploymentTimelineService` constructed from the existing session coordinator.

- [ ] **Step 1: Extend the existing App detail test stubs**

Add:

```swift
private enum DetailDeploymentOutcome: Sendable {
    case evidence(GitHubDeploymentTimelineEvidence)
    case failure
}

private actor DetailDeploymentLoader: GitHubDeploymentTimelineLoading {
    // record call count and exactSHA
}
```

The loader must record the SHA supplied by App so tests can prove App uses the builder's correlated base run.

- [ ] **Step 2: Write RED success test**

For exact correlation plus available Deployment capability:

```swift
#expect(detail.deliveryTimeline?.events.map(\.kind) == [
    .pullRequest, .merge, .execution, .deployment
])
#expect(await deploymentLoader.requestedSHAs() == ["landed-sha"])
```

Jobs must still be present.

- [ ] **Step 3: Write RED no-correlation and failure-isolation tests**

Required assertions:

```swift
#expect(await deploymentLoader.calls() == 0)
```

when the Delivery correlation is unavailable.

When Deployment loader throws:

```swift
#expect(detail.deliveryTimeline?.events.map(\.kind) == [
    .pullRequest, .merge, .execution
])
#expect(detail.rows.map(\.id) == ["7001"])
```

When Deployment returns empty evidence, preserve the same three-event timeline.

Cancellation must still propagate:

```swift
await #expect(throws: CancellationError.self) {
    try await model.loadActivityDetail(...)
}
```

- [ ] **Step 4: Add Deployment capability coverage to the detail fixture**

Update the synthetic installation permissions used by the success fixture:

```json
{
  "actions": "read",
  "pull_requests": "read",
  "deployments": "read"
}
```

Add a separate unavailable fixture with no `deployments` permission for the private repository.

Assert unavailable capability makes zero Deployment requests while preserving the correlated timeline.

Unknown capability remains requestable. Use a fixture that produces `.unverified` presentation and assert one Deployment load occurs.

- [ ] **Step 5: Verify RED**

Run:

```bash
mise exec -- tuist test SchneeBarAppTests -- -skipMacroValidation CODE_SIGNING_ALLOWED=NO
```

Expected: failure because the deployment loader argument/composition does not exist.

- [ ] **Step 6: Implement App composition**

Inside the existing successful timeline block:

```swift
let buildResult = timelineBuilder.buildResult(
    repositoryID: repository.id,
    evidence: evidence
)
var deliveryTimeline = buildResult.timeline

if let baseRun = buildResult.correlatedBaseRun,
   option.activityAccess.deployments != .unavailable
{
    do {
        let deploymentEvidence = try await deploymentTimelineLoader.deploymentEvidence(
            connection: profile.connection,
            identity: profile.account,
            clientID: profile.clientID,
            repository: repository,
            exactSHA: baseRun.headSHA
        )
        deliveryTimeline = timelineBuilder.appendDeployments(
            to: deliveryTimeline,
            evidence: deploymentEvidence
        )
    } catch let cancellation as CancellationError {
        throw cancellation
    } catch {
        // Preserve the already-correlated timeline.
    }
}
```

No Deployment request is made when `correlatedBaseRun == nil`.

Keep Jobs as the required branch exactly as today.

- [ ] **Step 7: Wire AppDelegate**

Add:

```swift
private let deploymentTimelineService: GitHubDeploymentTimelineService
```

Initialize it from the same `GitHubConnectionSessionCoordinator` and pass it to `loadActivityDetail`.

Do not wire it into `GitHubActivityProvider` or any refresh loop.

- [ ] **Step 8: Verify GREEN**

Run App tests. Expected: PASS.

- [ ] **Step 9: Commit**

```bash
git add Sources/SchneeBarApp Tests/SchneeBarAppTests/GitHubConnectionsRuntimeModelActivityDetailTests.swift
git commit -m "feat: enrich delivery timeline with deployments"
```

### Task 6: Surface Deployment capability and add deterministic UI/visual coverage

**Files:**
- Modify: `Sources/SchneeBarGitHubFeature/GitHubConnectionManagementView.swift`
- Modify: `Sources/SchneeBarApp/GitHubConnectionsRuntimeModel.swift`
- Modify: `Tests/SchneeBarAppTests/GitHubConnectionsRuntimeModelCapabilityPresentationTests.swift`
- Modify: `Sources/SchneeBarPreviewSupport/GitHubConnectionFixtures.swift`
- Modify: `Sources/SchneeBarPreviewSupport/ActivityDetailFixtures.swift`
- Modify: `Sources/SchneeBarVisualHarness/SchneeBarVisualHarnessApp.swift`
- Modify: `Sources/SchneeBarVisualSnapshotCLI/main.swift`
- Modify: `docs/DEVELOPMENT_PLAN.md`

**Interfaces:**
- Extend:

```swift
public struct GitHubRepositoryActivityAccessModel: Equatable, Sendable {
    public let actions: GitHubRepositoryActivityAccessPresentation
    public let reviewRequests: GitHubRepositoryActivityAccessPresentation
    public let checks: GitHubRepositoryActivityAccessPresentation
    public let deployments: GitHubRepositoryActivityAccessPresentation
}
```

- [ ] **Step 1: Write RED capability-presentation test**

In `GitHubConnectionsRuntimeModelCapabilityPresentationTests.swift`, provide synthetic capability evidence with:

```swift
.deployments: .available
```

and assert:

```swift
#expect(repository.activityAccess.deployments == .available)
```

Add unavailable and unknown/unverified coverage using the same mapping rules as the existing three surfaces.

- [ ] **Step 2: Verify RED**

Run:

```bash
mise exec -- tuist test SchneeBarAppTests -- -skipMacroValidation CODE_SIGNING_ALLOWED=NO
```

Expected: compile failure because `deployments` is absent from `GitHubRepositoryActivityAccessModel`.

- [ ] **Step 3: Extend the model and repository-management row**

Add `deployments` to the model initializer and mapping in `GitHubConnectionsRuntimeModel.managementModel`:

```swift
deployments: activityAccessPresentation(
    assessment?.state(for: .deployments, repositoryID: repository.id)
)
```

Add:

```swift
accessBadge("Deployments", access: repository.activityAccess.deployments)
```

to the repository row.

Include Deployments in `monitoredActivityAccess`, because the summary counts all surfaced access states. Rename the summary caption from `Activity source access` to `Feature access` so a detail-only Deployment capability is not described as a polling source.

Update monitoring copy so it does not imply Deployments is background-polled. Preferred wording:

```text
SchneeBar monitors bounded Workflow, Review Request, and Check activity, while Deployment access is used only when delivery detail is opened.
```

- [ ] **Step 4: Verify GREEN capability tests**

Run App tests. Expected: PASS.

- [ ] **Step 5: Add deterministic Activity Detail fixtures**

Add scenarios:

```swift
case deploymentProductionSuccess = "deployment-production-success"
case deploymentStagingRunning = "deployment-staging-running"
case deploymentNone = "deployment-none"
case deploymentCapabilityUnavailable = "deployment-capability-unavailable"
case deploymentBoundedMultiple = "deployment-bounded-multiple"
```

Use only synthetic URLs such as:

```text
https://deploy.example.test/production
https://deploy.example.test/staging
```

The production success timeline must have:

```swift
[.pullRequest, .merge, .execution, .deployment]
```

The bounded-multiple fixture may display at most three deployment events.

- [ ] **Step 6: Update GitHub management fixtures**

Update every `GitHubRepositoryActivityAccessModel(...)` construction to provide `deployments`.

Make the mixed-capability fixture visibly include at least:

- Deployments available;
- Deployments unverified;
- Deployments unavailable.

This exercises the new badge in the existing management snapshots.

- [ ] **Step 7: Register Light/Dark snapshots**

In `SchneeBarVisualSnapshotCLI`, render all Deployment Activity Detail scenarios for both appearances. Keep existing deterministic renderer behavior and current 340-point detail width.

Ensure the Visual Harness defaults to a deployment-enriched detail scenario so manual inspection exposes the new surface.

- [ ] **Step 8: Update the development roadmap**

In Phase 4, move Deployment Timeline enrichment to Implemented. Keep these items incomplete:

- Environment inventory/protection rules;
- standalone deployment activity/history;
- persisted delivery history;
- repository default-branch discovery;
- recovery notifications.

Update Current implementation priority so Environment metadata/protection or default-branch/history work is next, not the already-completed exact-SHA Deployment enrichment.

- [ ] **Step 9: Run focused and full visual/regression verification**

Run:

```bash
mise exec -- tuist test SchneeBarAppTests -- -skipMacroValidation CODE_SIGNING_ALLOWED=NO
mise exec -- tuist test SchneeBarGitHubActivityProviderTests -- -skipMacroValidation CODE_SIGNING_ALLOWED=NO
mise exec -- tuist test SchneeBarGitHubTests -- -skipMacroValidation CODE_SIGNING_ALLOWED=NO
mise exec -- tuist test -- -skipMacroValidation CODE_SIGNING_ALLOWED=NO
rm -rf _visual/candidate && mkdir -p _visual/candidate
mise exec -- tuist run SchneeBarVisualSnapshotCLI -- --output "$PWD/_visual/candidate"
```

Expected: all tests PASS and all new Light/Dark deployment scenarios render.

- [ ] **Step 10: Commit**

```bash
git add Sources/SchneeBarGitHubFeature Sources/SchneeBarApp/GitHubConnectionsRuntimeModel.swift Sources/SchneeBarPreviewSupport Sources/SchneeBarVisualHarness Sources/SchneeBarVisualSnapshotCLI Tests/SchneeBarAppTests/GitHubConnectionsRuntimeModelCapabilityPresentationTests.swift docs/DEVELOPMENT_PLAN.md
git commit -m "feat: surface deployment access and visual coverage"
```

### Task 7: Exact-head security/review/merge gate

**Files:** No new production scope unless review or verification finds a defect.

**Interfaces:** None.

- [ ] **Step 1: Self-review spec coverage**

Check the final diff against every acceptance criterion in the spec. Specifically verify:

- exact correlated SHA is the only Deployment correlation key;
- Environment API is absent;
- no Deployment request is added to background Activity polling;
- list/status pagination is first-page-only;
- max three status requests;
- enrichment max four actual HTTP requests;
- total Delivery detail max eleven actual HTTP requests;
- Deployment failure preserves Jobs and PR/merge/execution;
- unavailable capability skips;
- unknown capability requests;
- external URLs are HTTPS/no-credentials sanitized;
- no raw SHA/default-branch wording leaks to UI;
- DTOs stay out of Core/SwiftUI.

- [ ] **Step 2: Check discussion state**

Require:

- zero unresolved review threads;
- no requested-changes review;
- PR remains mergeable.

- [ ] **Step 3: Verify the exact implementation head**

Require GitHub Actions on the same immutable head SHA:

- CI: success;
- Visual Regression: success;
- CodeQL: success after Ready-for-review.

Do not reuse success from an older head.

- [ ] **Step 4: Merge only the verified head**

Use squash merge with `expected_head_sha` equal to the verified SHA.

Suggested squash title:

```text
feat: add GitHub deployment timeline enrichment
```

Do not merge if the head moves after verification.

# GitHub Environment Enrichment Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Enrich already-correlated exact-SHA GitHub Deployment timeline events with bounded, read-only repository Environment protection metadata while preserving existing Jobs, Delivery correlation, Deployment behavior, and background polling budgets.

**Architecture:** Add a focused Environment REST client and catalog service in `SchneeBarGitHub`, then pass the optional catalog into the existing pure `GitHubDeliveryTimelineBuilder.appendDeployments` path. Environment loading is attempted only after bounded exact-SHA Deployment evidence exists and only when existing Actions capability is not definitively unavailable; failures are isolated so the current Deployment events remain unchanged.

**Tech Stack:** Swift 6.3, SwiftUI/AppKit, Swift Testing, Tuist 4.203.1, GitHub REST API, GitHub Actions CI / Visual Regression / CodeQL.

**Spec:** `docs/superpowers/specs/2026-09-20-github-environment-enrichment-design.md`

## Global Constraints

- Stacked implementation base is PR #51 / `feat/github-deployment-timeline@69572a619c013273050565a1171fb04ae0644f81` until PR #51 lands.
- macOS production target remains 15.0.
- Xcode 26.6 / Swift 6.3 remain the stable baseline.
- No GitHub Environment DTO may leak into `SchneeBarCore` or SwiftUI.
- No Environment request may be added to normal Developer Activity polling.
- Environment metadata is presentation-only and never establishes Deployment correlation.
- Environment loading happens only after eligible exact-SHA Deployment evidence exists.
- Environment enrichment performs at most 1 feature HTTP request.
- The complete explicit-detail Delivery path performs at most 12 feature HTTP requests.
- Environment list is exactly page 1 with `per_page <= 100`; do not paginate.
- Actions capability `.unavailable` skips Environment loading; `.unknown` remains requestable for explicit detail.
- Environment technical failure must preserve Jobs, PR/merge/execution events, and existing Deployment events.
- Provider Environment `url` and `html_url` values are discarded.
- Reviewer identities, team identities, avatar URLs, and reviewer IDs are discarded.
- Custom deployment protection-rule endpoints and custom branch-policy pattern endpoints are out of scope.
- No Environment write, secret, variable, administration, or approval endpoint is allowed.
- No raw SHA is shown in the UI.
- Production changes follow TDD: write a failing test, observe the intended RED, implement the minimum change, then verify GREEN.
- Public fixtures use synthetic repositories, synthetic Environment names, and `example.test` only.
- Do not alter PR #51's verified implementation head while it remains open.

## Review Focus

1. **Malformed catalog count:** a payload where `total_count < environments.count` must fail with `.invalidResponse`, never silently produce an impossible non-truncated catalog.
2. **Missing versus explicit-null branch policy:** a missing `deployment_branch_policy` key must normalize to `.unknown`; an explicitly present `null` key must normalize to `.allBranches`.
3. **Duplicate normalized Environment names:** if a catalog unexpectedly contains two case-insensitive matches for one Deployment Environment, the builder must leave that Deployment detail unchanged.
4. **Zero-value protection rules:** zero required reviewers and a zero-minute wait timer must not emit misleading `0 reviewers` or `0m wait` UI text.
5. **Unknown/new protection rules:** unknown rule types must be ignored without producing a false `No protection` claim or invalidating otherwise usable built-in metadata.

---

### Task 1: Add a bounded GitHub Environment REST client

**Files:**
- Create: `Sources/SchneeBarGitHub/GitHubEnvironmentClient.swift`
- Create: `Tests/SchneeBarGitHubTests/GitHubEnvironmentClientTests.swift`

**Interfaces:**
- Consumes: `GitHubHTTPTransport`, `GitHubRepositoryAccess`, `GitHubConnection`, `GitHubCredential`, `GitHubEndpointResolver`, `GitHubRESTAPIVersionPolicy`.
- Produces:

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

    public init(
        waitTimerMinutes: Int?,
        requiredReviewerCount: Int?,
        preventsSelfReview: Bool?,
        branchPolicy: GitHubEnvironmentBranchPolicy
    )
}

public struct GitHubEnvironment: Equatable, Sendable {
    public let id: Int64
    public let name: String
    public let protection: GitHubEnvironmentProtection
    public let createdAt: Date?
    public let updatedAt: Date?

    public init(
        id: Int64,
        name: String,
        protection: GitHubEnvironmentProtection,
        createdAt: Date?,
        updatedAt: Date?
    )
}

public struct GitHubEnvironmentCatalog: Equatable, Sendable {
    public let totalCount: Int
    public let environments: [GitHubEnvironment]
    public let isTruncated: Bool

    public init(
        totalCount: Int,
        environments: [GitHubEnvironment],
        isTruncated: Bool
    )
}

public enum GitHubEnvironmentClientError: Error, Equatable, Sendable {
    case invalidCredential
    case invalidRepository
    case invalidResponse
    case httpStatus(Int)
}

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

- [ ] **Step 1: Write RED request/normalization tests**

Create a queue/recording transport matching the style in `GitHubDeploymentClientTests.swift`.

Add a hosted success test with a payload equivalent to:

```json
{
  "total_count": 2,
  "environments": [
    {
      "id": 101,
      "node_id": "ENV_101",
      "name": "production",
      "url": "https://api.github.com/repos/octocat/project/environments/production",
      "html_url": "https://github.com/octocat/project/deployments/activity_log?environments_filter=production",
      "created_at": "2026-09-20T00:00:00Z",
      "updated_at": "2026-09-20T00:01:00Z",
      "protection_rules": [
        {
          "id": 1,
          "node_id": "RULE_1",
          "type": "required_reviewers",
          "prevent_self_review": true,
          "reviewers": [
            {"type":"User","reviewer":{"id":55,"login":"private-user"}},
            {"type":"Team","reviewer":{"id":66,"name":"private-team"}}
          ]
        },
        {
          "id": 2,
          "node_id": "RULE_2",
          "type": "wait_timer",
          "wait_timer": 30
        },
        {
          "id": 3,
          "node_id": "RULE_3",
          "type": "future_rule",
          "configuration": {"opaque": true}
        }
      ],
      "deployment_branch_policy": {
        "protected_branches": false,
        "custom_branch_policies": true
      }
    },
    {
      "id": 102,
      "name": "staging",
      "created_at": null,
      "updated_at": null,
      "protection_rules": [],
      "deployment_branch_policy": null
    }
  ]
}
```

Assertions:

```swift
#expect(catalog.totalCount == 2)
#expect(catalog.environments.count == 2)
#expect(!catalog.isTruncated)

let production = try #require(catalog.environments.first)
#expect(production.id == 101)
#expect(production.name == "production")
#expect(production.protection.requiredReviewerCount == 2)
#expect(production.protection.preventsSelfReview == true)
#expect(production.protection.waitTimerMinutes == 30)
#expect(production.protection.branchPolicy == .customBranches)

let staging = try #require(catalog.environments.last)
#expect(staging.protection.branchPolicy == .allBranches)
```

Assert the request exactly:

```swift
let request = try #require(await transport.recordedRequests().first)
#expect(request.httpMethod == "GET")
#expect(request.url?.path == "/repos/octocat/project/environments")
#expect(queryValue("per_page", in: request) == "100")
#expect(queryValue("page", in: request) == "1")
#expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer ghu_environment")
#expect(request.value(forHTTPHeaderField: "Accept") == "application/vnd.github+json")
#expect(
    request.value(forHTTPHeaderField: "X-GitHub-Api-Version")
        == GitHubRESTAPIVersionPolicy.currentVersion
)
```

Also assert that neither public normalized model contains provider `url`, `html_url`, reviewer login, team name, reviewer ID, or avatar fields by construction.

- [ ] **Step 2: Write RED input/bounds tests**

Add tests proving:

```swift
_ = try await client.environments(
    repository: repository,
    connection: connection,
    credential: credential,
    limit: 0
)
// per_page == 1

_ = try await client.environments(
    repository: repository,
    connection: connection,
    credential: credential,
    limit: 500
)
// per_page == 100
```

Add invalid-input assertions:

```swift
await #expect(throws: GitHubEnvironmentClientError.invalidCredential) {
    _ = try await client.environments(
        repository: validRepository,
        connection: validConnection,
        credential: GitHubCredential(accessToken: "   ")
    )
}

await #expect(throws: GitHubEnvironmentClientError.invalidRepository) {
    _ = try await client.environments(
        repository: invalidRepository,
        connection: validConnection,
        credential: validCredential
    )
}

#expect(await transport.recordedRequests().isEmpty)
```

- [ ] **Step 3: Write RED payload-integrity tests**

Pin these failure cases:

```swift
await #expect(throws: GitHubEnvironmentClientError.invalidResponse) {
    // total_count == -1
}

await #expect(throws: GitHubEnvironmentClientError.invalidResponse) {
    // total_count == 0 but one decoded environment exists
}

await #expect(throws: GitHubEnvironmentClientError.invalidResponse) {
    // environment id == 0
}

await #expect(throws: GitHubEnvironmentClientError.invalidResponse) {
    // environment name == "   "
}

await #expect(throws: GitHubEnvironmentClientError.invalidResponse) {
    // two wait_timer protection rules
}

await #expect(throws: GitHubEnvironmentClientError.invalidResponse) {
    // two required_reviewers protection rules
}
```

Add truncation:

```swift
#expect(
    try await client.environments(
        repository: repository,
        connection: connection,
        credential: credential
    ).isTruncated
)
// total_count == 101, page-1 environments.count == 100
```

No second request may occur.

- [ ] **Step 4: Write RED branch-policy presence tests**

Use three payloads:

```json
{"deployment_branch_policy": null}
```

Expected:

```swift
#expect(environment.protection.branchPolicy == .allBranches)
```

Missing key entirely:

```json
{}
```

Expected:

```swift
#expect(environment.protection.branchPolicy == .unknown)
```

Contradictory object:

```json
{
  "deployment_branch_policy": {
    "protected_branches": true,
    "custom_branch_policies": true
  }
}
```

Expected:

```swift
#expect(environment.protection.branchPolicy == .unknown)
```

Also cover:

```swift
(false, true)  -> .customBranches
(true, false)  -> .protectedBranches
(false, false) -> .unknown
```

- [ ] **Step 5: Write RED unknown/zero-rule tests**

Unknown future rule must not invalidate the environment:

```swift
#expect(environment.protection.waitTimerMinutes == nil)
#expect(environment.protection.requiredReviewerCount == nil)
```

Zero values normalize as valid data but are left for presentation filtering:

```swift
#expect(environment.protection.waitTimerMinutes == 0)
#expect(environment.protection.requiredReviewerCount == 0)
```

Negative wait timers fail:

```swift
await #expect(throws: GitHubEnvironmentClientError.invalidResponse) {
    // wait_timer == -1
}
```

- [ ] **Step 6: Write RED enterprise/version tests**

Follow existing client conventions.

Explicit GHES:

```swift
#expect(request.url?.host == "github.internal.example")
#expect(request.url?.port == 8443)
#expect(request.url?.path == "/api/v3/repos/acme/service-api/environments")
#expect(
    request.value(forHTTPHeaderField: "X-GitHub-Api-Version")
        == "2022-11-28"
)
```

Unversioned GHES:

```swift
#expect(request.value(forHTTPHeaderField: "X-GitHub-Api-Version") == nil)
```

HTTP failure:

```swift
await #expect(throws: GitHubEnvironmentClientError.httpStatus(403)) {
    _ = try await client.environments(
        repository: try environmentRepository(),
        connection: try environmentGitHubDotComConnection(),
        credential: GitHubCredential(accessToken: "ghu_environment")
    )
}
```

- [ ] **Step 7: Verify RED**

Run:

```bash
mise exec -- tuist test SchneeBarGitHubTests -- -skipMacroValidation CODE_SIGNING_ALLOWED=NO
```

Expected: compile failure because `GitHubEnvironmentClient`, `GitHubEnvironmentCatalog`, and related types do not exist.

- [ ] **Step 8: Implement the minimum client**

Create `GitHubEnvironmentClient.swift`.

Use private DTOs:

```swift
private struct EnvironmentListPayload: Decodable {
    let totalCount: Int
    let environments: [EnvironmentPayload]
}

private struct EnvironmentPayload: Decodable {
    let id: Int64
    let name: String
    let protectionRules: [ProtectionRulePayload]
    let deploymentBranchPolicy: DeploymentBranchPolicyPayload?
    let deploymentBranchPolicyWasPresent: Bool
    let createdAt: String?
    let updatedAt: String?

    enum CodingKeys: String, CodingKey {
        case id
        case name
        case protectionRules = "protection_rules"
        case deploymentBranchPolicy = "deployment_branch_policy"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(Int64.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        protectionRules = try container.decodeIfPresent(
            [ProtectionRulePayload].self,
            forKey: .protectionRules
        ) ?? []
        deploymentBranchPolicyWasPresent = container.contains(.deploymentBranchPolicy)
        deploymentBranchPolicy = try container.decodeIfPresent(
            DeploymentBranchPolicyPayload.self,
            forKey: .deploymentBranchPolicy
        )
        createdAt = try container.decodeIfPresent(String.self, forKey: .createdAt)
        updatedAt = try container.decodeIfPresent(String.self, forKey: .updatedAt)
    }
}

private struct ProtectionRulePayload: Decodable {
    let type: String
    let waitTimer: Int?
    let preventSelfReview: Bool?
    let reviewers: [ReviewerPayload]?

    enum CodingKeys: String, CodingKey {
        case type
        case waitTimer = "wait_timer"
        case preventSelfReview = "prevent_self_review"
        case reviewers
    }
}

private struct ReviewerPayload: Decodable {}

private struct DeploymentBranchPolicyPayload: Decodable {
    let protectedBranches: Bool?
    let customBranchPolicies: Bool?

    enum CodingKeys: String, CodingKey {
        case protectedBranches = "protected_branches"
        case customBranchPolicies = "custom_branch_policies"
    }
}
```

Construct request:

```swift
var components = URLComponents(
    url: endpoints.apiBaseURL
        .appendingPathComponent("repos", isDirectory: true)
        .appendingPathComponent(owner, isDirectory: true)
        .appendingPathComponent(name, isDirectory: true)
        .appendingPathComponent("environments", isDirectory: false),
    resolvingAgainstBaseURL: false
)
components?.queryItems = [
    URLQueryItem(name: "per_page", value: String(clampedLimit)),
    URLQueryItem(name: "page", value: "1"),
]
```

Headers:

```swift
request.httpMethod = "GET"
request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
if let version = apiVersion(for: connection) {
    request.setValue(version, forHTTPHeaderField: "X-GitHub-Api-Version")
}
```

Normalize built-in rules with duplicate detection:

```swift
let waitRules = payload.protectionRules.filter { $0.type == "wait_timer" }
guard waitRules.count <= 1 else {
    throw GitHubEnvironmentClientError.invalidResponse
}

let reviewerRules = payload.protectionRules.filter { $0.type == "required_reviewers" }
guard reviewerRules.count <= 1 else {
    throw GitHubEnvironmentClientError.invalidResponse
}
```

Validate:

```swift
guard payload.id > 0,
      let environmentName = nonEmpty(payload.name)
else {
    throw GitHubEnvironmentClientError.invalidResponse
}

if let wait = waitRules.first?.waitTimer, wait < 0 {
    throw GitHubEnvironmentClientError.invalidResponse
}
```

Normalize branch policy:

```swift
private func branchPolicy(
    payload: DeploymentBranchPolicyPayload?,
    keyWasPresent: Bool
) -> GitHubEnvironmentBranchPolicy {
    guard keyWasPresent else { return .unknown }
    guard let payload else { return .allBranches }

    switch (payload.protectedBranches, payload.customBranchPolicies) {
    case (true?, false?): return .protectedBranches
    case (false?, true?): return .customBranches
    default: return .unknown
    }
}
```

Preserve current ISO-8601 helper behavior: fractional seconds first, then standard ISO-8601, and return `nil` for missing/invalid optional timestamps.

Do not decode or retain provider `url`, `html_url`, reviewer identity fields, or unknown protection-rule payload fields.

- [ ] **Step 9: Verify GREEN**

Run:

```bash
mise exec -- tuist test SchneeBarGitHubTests -- -skipMacroValidation CODE_SIGNING_ALLOWED=NO
```

Expected: PASS, including existing Deployment client tests.

- [ ] **Step 10: Commit**

```bash
git add Sources/SchneeBarGitHub/GitHubEnvironmentClient.swift Tests/SchneeBarGitHubTests/GitHubEnvironmentClientTests.swift
git commit -m "feat: add bounded GitHub environment client"
```

---

### Task 2: Add the one-request Environment catalog service

**Files:**
- Create: `Sources/SchneeBarGitHub/GitHubEnvironmentCatalogService.swift`
- Create: `Tests/SchneeBarGitHubTests/GitHubEnvironmentCatalogServiceTests.swift`

**Interfaces:**
- Consumes: `GitHubConnectionSessionCoordinator`, `GitHubEnvironmentClient`.
- Produces:

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

    public func environmentCatalog(
        connection: GitHubConnection,
        identity: GitHubAccountIdentity,
        clientID: String?,
        repository: GitHubRepositoryAccess
    ) async throws -> GitHubEnvironmentCatalog
}
```

- [ ] **Step 1: Write RED service success/request-count test**

Create a credential store and recording transport.

Use:

```swift
let service = GitHubEnvironmentCatalogService(
    sessionCoordinator: coordinator,
    environmentClient: GitHubEnvironmentClient(transport: transport)
)

let catalog = try await service.environmentCatalog(
    connection: connection,
    identity: identity,
    clientID: nil,
    repository: repository
)

#expect(catalog.environments.map(\.name) == ["production"])
#expect(await transport.recordedRequests().count == 1)
#expect(await credentialStore.loadCount() == 1)
```

The single feature request must be the Environment list request.

- [ ] **Step 2: Write RED cancellation test**

Use a pre-cancelled Task:

```swift
let task = Task {
    try await service.environmentCatalog(
        connection: connection,
        identity: identity,
        clientID: nil,
        repository: repository
    )
}
task.cancel()

await #expect(throws: CancellationError.self) {
    _ = try await task.value
}
#expect(await transport.recordedRequests().isEmpty)
```

Pin cancellation immediately before the feature request rather than converting it into an empty catalog.

- [ ] **Step 3: Write RED client-error propagation test**

Return HTTP 404 from the transport:

```swift
await #expect(throws: GitHubEnvironmentClientError.httpStatus(404)) {
    _ = try await service.environmentCatalog(
        connection: connection,
        identity: identity,
        clientID: nil,
        repository: repository
    )
}
```

The service must not swallow the error; App composition owns best-effort isolation.

- [ ] **Step 4: Verify RED**

Run:

```bash
mise exec -- tuist test SchneeBarGitHubTests -- -skipMacroValidation CODE_SIGNING_ALLOWED=NO
```

Expected: compile failure because `GitHubEnvironmentCatalogService` does not exist.

- [ ] **Step 5: Implement the minimum service**

```swift
public struct GitHubEnvironmentCatalogService:
    GitHubEnvironmentCatalogLoading,
    Sendable
{
    private let sessionCoordinator: GitHubConnectionSessionCoordinator
    private let environmentClient: GitHubEnvironmentClient

    public init(
        sessionCoordinator: GitHubConnectionSessionCoordinator,
        environmentClient: GitHubEnvironmentClient = .init()
    ) {
        self.sessionCoordinator = sessionCoordinator
        self.environmentClient = environmentClient
    }

    public func environmentCatalog(
        connection: GitHubConnection,
        identity: GitHubAccountIdentity,
        clientID: String?,
        repository: GitHubRepositoryAccess
    ) async throws -> GitHubEnvironmentCatalog {
        let credential = try await sessionCoordinator.authorizedCredential(
            connection: connection,
            identity: identity,
            clientID: clientID
        )

        try Task.checkCancellation()

        return try await environmentClient.environments(
            repository: repository,
            connection: connection,
            credential: credential,
            limit: 100
        )
    }
}
```

Do not cache or retry in this slice.

- [ ] **Step 6: Verify GREEN**

Run the same GitHub test target. Expected: PASS.

- [ ] **Step 7: Commit**

```bash
git add Sources/SchneeBarGitHub/GitHubEnvironmentCatalogService.swift Tests/SchneeBarGitHubTests/GitHubEnvironmentCatalogServiceTests.swift
git commit -m "feat: load GitHub environment catalog on demand"
```

---

### Task 3: Enrich Deployment events in the pure provider builder

**Files:**
- Modify: `Sources/SchneeBarGitHubActivityProvider/GitHubDeliveryTimelineBuilder.swift`
- Modify: `Tests/SchneeBarGitHubActivityProviderTests/GitHubDeliveryTimelineBuilderTests.swift`

**Interfaces:**
- Consumes: `GitHubDeploymentTimelineEvidence`, optional `GitHubEnvironmentCatalog`.
- Produces the source-compatible overload/defaulted signature:

```swift
public func appendDeployments(
    to timeline: DeliveryTimelineSnapshot,
    evidence: GitHubDeploymentTimelineEvidence,
    environmentCatalog: GitHubEnvironmentCatalog? = nil
) -> DeliveryTimelineSnapshot
```

Existing callers that omit `environmentCatalog` must preserve current PR #51 behavior.

- [ ] **Step 1: Write RED exact Environment-match test**

Build the existing correlated timeline and Deployment evidence:

```swift
let environmentCatalog = GitHubEnvironmentCatalog(
    totalCount: 1,
    environments: [
        GitHubEnvironment(
            id: 301,
            name: " Production ",
            protection: GitHubEnvironmentProtection(
                waitTimerMinutes: 30,
                requiredReviewerCount: 2,
                preventsSelfReview: true,
                branchPolicy: .customBranches
            ),
            createdAt: nil,
            updatedAt: nil
        ),
    ],
    isTruncated: false
)

let snapshot = GitHubDeliveryTimelineBuilder().appendDeployments(
    to: original,
    evidence: deploymentEvidence(
        sha: "landed-sha",
        deploymentEnvironment: "production",
        statusEnvironment: "PRODUCTION",
        state: .success,
        production: true
    ),
    environmentCatalog: environmentCatalog
)

#expect(snapshot.events.last?.detail ==
    "Succeeded · Production · 2 reviewers · 30m wait · No self-review · Custom branches")
```

This pins trimming + case-insensitive exact matching.

- [ ] **Step 2: Write RED Status-environment precedence test**

Given:

```swift
deployment.environment == "staging"
status.environment == "production"
```

and catalog entries for both, assert the production catalog entry is used because status Environment is already the PR #51 display authority.

- [ ] **Step 3: Write RED ambiguous/unmatched/empty tests**

Duplicate normalized names:

```swift
let catalog = GitHubEnvironmentCatalog(
    totalCount: 2,
    environments: [
        environment(name: "production", reviewers: 1),
        environment(name: "PRODUCTION", reviewers: 3),
    ],
    isTruncated: false
)

#expect(enriched.events.last?.detail == "Succeeded · Production")
```

Unmatched page-1 environment:

```swift
#expect(enriched.events.last?.detail == "Succeeded · Production")
```

Empty Deployment/Status environment:

```swift
#expect(enriched.events.last?.title == "Deployment · Unknown environment")
#expect(enriched.events.last?.detail == "Succeeded")
```

No catalog:

```swift
#expect(
    builder.appendDeployments(to: original, evidence: evidence)
    == existingPR51ExpectedSnapshot
)
```

- [ ] **Step 4: Write RED presentation-order/zero-value tests**

Zero values:

```swift
let protection = GitHubEnvironmentProtection(
    waitTimerMinutes: 0,
    requiredReviewerCount: 0,
    preventsSelfReview: false,
    branchPolicy: .protectedBranches
)

#expect(event.detail == "Succeeded · Production · Protected branches")
```

No recognized visible metadata:

```swift
let protection = GitHubEnvironmentProtection(
    waitTimerMinutes: nil,
    requiredReviewerCount: nil,
    preventsSelfReview: nil,
    branchPolicy: .allBranches
)

#expect(event.detail == "Succeeded · Production")
```

Hour/day compact formatting:

```swift
60   -> "1h wait"
120  -> "2h wait"
1440 -> "1d wait"
2880 -> "2d wait"
90   -> "90m wait"
```

Use singular/plural reviewer labels:

```swift
1 -> "1 reviewer"
2 -> "2 reviewers"
```

- [ ] **Step 5: Write RED invariant tests**

Environment metadata must not change:

```swift
#expect(enriched.status == originalWithDeployments.status)
#expect(enriched.confidence == originalWithDeployments.confidence)
#expect(enriched.events.map(\.kind) == originalWithDeployments.events.map(\.kind))
#expect(enriched.events.last?.state == originalWithDeployments.events.last?.state)
#expect(
    enriched.events.last?.destinationURL
        == originalWithDeployments.events.last?.destinationURL
)
```

The catalog may only extend Deployment event detail text.

- [ ] **Step 6: Verify RED**

Run:

```bash
mise exec -- tuist test SchneeBarGitHubActivityProviderTests -- -skipMacroValidation CODE_SIGNING_ALLOWED=NO
```

Expected: compile failure because `appendDeployments` does not accept `environmentCatalog`.

- [ ] **Step 7: Implement Environment lookup + compact labels**

Change signature:

```swift
public func appendDeployments(
    to timeline: DeliveryTimelineSnapshot,
    evidence: GitHubDeploymentTimelineEvidence,
    environmentCatalog: GitHubEnvironmentCatalog? = nil
) -> DeliveryTimelineSnapshot
```

Resolve the Environment from the same normalized display source:

```swift
let environment = normalizedEnvironment(
    status?.environment,
    fallback: deployment.environment
)
let matchedEnvironment = matchedEnvironment(
    named: environment,
    in: environmentCatalog
)
```

Match helper:

```swift
private func matchedEnvironment(
    named environmentName: String,
    in catalog: GitHubEnvironmentCatalog?
) -> GitHubEnvironment? {
    guard let catalog,
          environmentName != "Unknown environment"
    else {
        return nil
    }

    let key = normalizedEnvironmentKey(environmentName)
    guard !key.isEmpty else { return nil }

    let matches = catalog.environments.filter {
        normalizedEnvironmentKey($0.name) == key
    }
    guard matches.count == 1 else { return nil }
    return matches[0]
}

private func normalizedEnvironmentKey(_ value: String) -> String {
    value
        .trimmingCharacters(in: .whitespacesAndNewlines)
        .lowercased()
}
```

Extend detail generation:

```swift
private func deploymentDetail(
    statusLabel: String,
    deployment: GitHubDeployment,
    environment: GitHubEnvironment?
) -> String {
    var parts = [statusLabel]

    if deployment.isProductionEnvironment {
        parts.append("Production")
    }
    if deployment.isTransientEnvironment {
        parts.append("Transient")
    }

    if let reviewerCount = environment?.protection.requiredReviewerCount,
       reviewerCount > 0
    {
        parts.append(
            reviewerCount == 1
                ? "1 reviewer"
                : "\(reviewerCount) reviewers"
        )
    }

    if let waitTimer = environment?.protection.waitTimerMinutes,
       waitTimer > 0
    {
        parts.append(waitTimerLabel(waitTimer))
    }

    if environment?.protection.preventsSelfReview == true {
        parts.append("No self-review")
    }

    switch environment?.protection.branchPolicy {
    case .protectedBranches:
        parts.append("Protected branches")
    case .customBranches:
        parts.append("Custom branches")
    case .allBranches, .unknown, .none:
        break
    }

    return parts.joined(separator: " · ")
}
```

Wait label:

```swift
private func waitTimerLabel(_ minutes: Int) -> String {
    if minutes % 1_440 == 0 {
        return "\(minutes / 1_440)d wait"
    }
    if minutes % 60 == 0 {
        return "\(minutes / 60)h wait"
    }
    return "\(minutes)m wait"
}
```

Do not add any Core fields.

- [ ] **Step 8: Verify GREEN**

Run the same provider test target. Expected: PASS.

- [ ] **Step 9: Commit**

```bash
git add Sources/SchneeBarGitHubActivityProvider/GitHubDeliveryTimelineBuilder.swift Tests/SchneeBarGitHubActivityProviderTests/GitHubDeliveryTimelineBuilderTests.swift
git commit -m "feat: enrich deployment events with environment protection"
```

---

### Task 4: Wire Environment enrichment into explicit Activity detail only

**Files:**
- Modify: `Sources/SchneeBarApp/GitHubConnectionsRuntimeModel+ActivityDetail.swift`
- Modify: `Sources/SchneeBarApp/SchneeBarApp.swift`
- Modify: `Tests/SchneeBarAppTests/GitHubConnectionsRuntimeModelActivityDetailTests.swift`

**Interfaces:**
- Consumes: `GitHubEnvironmentCatalogLoading`.
- Changes App detail signature to:

```swift
func loadActivityDetail(
    for item: ActivityItem,
    jobService: GitHubWorkflowJobService,
    timelineLoader: any GitHubDeliveryTimelineLoading,
    deploymentTimelineLoader: any GitHubDeploymentTimelineLoading,
    environmentCatalogLoader: any GitHubEnvironmentCatalogLoading,
    timelineBuilder: GitHubDeliveryTimelineBuilder = GitHubDeliveryTimelineBuilder(),
    detailMapper: GitHubActivityJobDetailMapper = GitHubActivityJobDetailMapper()
) async throws -> ActivityDetailSnapshot
```

- [ ] **Step 1: Extend App test fakes with an Environment loader**

Add:

```swift
private actor DetailEnvironmentCatalogLoader:
    GitHubEnvironmentCatalogLoading
{
    private let result: Result<GitHubEnvironmentCatalog, Error>
    private var repositories: [Int64] = []

    init(result: Result<GitHubEnvironmentCatalog, Error>) {
        self.result = result
    }

    func environmentCatalog(
        connection: GitHubConnection,
        identity: GitHubAccountIdentity,
        clientID: String?,
        repository: GitHubRepositoryAccess
    ) async throws -> GitHubEnvironmentCatalog {
        repositories.append(repository.id)
        return try result.get()
    }

    func requestCount() -> Int {
        repositories.count
    }
}
```

For tests that do not care about Environment enrichment, inject a loader returning an empty catalog.

- [ ] **Step 2: Write RED successful Environment-enrichment test**

Use deployment evidence with one production Deployment and a successful Environment catalog.

Assert:

```swift
let detail = try await model.loadActivityDetail(
    for: item,
    jobService: jobService,
    timelineLoader: timelineLoader,
    deploymentTimelineLoader: deploymentLoader,
    environmentCatalogLoader: environmentLoader
)

#expect(await environmentLoader.requestCount() == 1)
#expect(detail.deliveryTimeline?.events.last?.kind == .deployment)
#expect(
    detail.deliveryTimeline?.events.last?.detail
        == "Succeeded · Production · 2 reviewers · 30m wait · Custom branches"
)
```

- [ ] **Step 3: Write RED zero-request trigger tests**

Pin each trigger separately.

No correlated base run:

```swift
#expect(await deploymentLoader.requestCount() == 0)
#expect(await environmentLoader.requestCount() == 0)
```

Deployment capability unavailable:

```swift
#expect(await deploymentLoader.requestCount() == 0)
#expect(await environmentLoader.requestCount() == 0)
```

Deployment technical failure:

```swift
#expect(await environmentLoader.requestCount() == 0)
```

Empty Deployment evidence:

```swift
#expect(await deploymentLoader.requestCount() == 1)
#expect(await environmentLoader.requestCount() == 0)
```

Actions capability unavailable with valid Deployment evidence:

```swift
#expect(await deploymentLoader.requestCount() == 1)
#expect(await environmentLoader.requestCount() == 0)
#expect(detail.deliveryTimeline?.events.last?.kind == .deployment)
```

- [ ] **Step 4: Write RED unknown Actions-capability test**

For existing management capability `.unverified`:

```swift
#expect(await environmentLoader.requestCount() == 1)
```

This must match the explicit-detail conservative requestability policy.

- [ ] **Step 5: Write RED Environment failure-isolation test**

Environment loader throws a technical error:

```swift
let detail = try await model.loadActivityDetail(
    for: item,
    jobService: jobService,
    timelineLoader: timelineLoader,
    deploymentTimelineLoader: deploymentLoader,
    environmentCatalogLoader: environmentLoader
)

#expect(await environmentLoader.requestCount() == 1)
#expect(detail.deliveryTimeline?.status == .correlated)
#expect(detail.deliveryTimeline?.events.last?.kind == .deployment)
#expect(detail.deliveryTimeline?.events.last?.detail == "Succeeded · Production")
#expect(!detail.rows.isEmpty)
```

Do not turn the timeline into `.temporarilyUnavailable`.

- [ ] **Step 6: Write RED Environment cancellation test**

Environment loader throws `CancellationError`:

```swift
await #expect(throws: CancellationError.self) {
    _ = try await model.loadActivityDetail(
        for: item,
        jobService: jobService,
        timelineLoader: timelineLoader,
        deploymentTimelineLoader: deploymentLoader,
        environmentCatalogLoader: environmentLoader
    )
}
```

Cancellation must not be swallowed by best-effort isolation.

- [ ] **Step 7: Verify RED**

Run:

```bash
mise exec -- tuist test SchneeBarAppTests -- -skipMacroValidation CODE_SIGNING_ALLOWED=NO
```

Expected: compile failures for the new `environmentCatalogLoader` argument or missing protocol implementation.

- [ ] **Step 8: Implement App composition**

Inside the successful Deployment branch:

```swift
let deploymentEvidence = try await deploymentTimelineLoader.deploymentEvidence(
    connection: profile.connection,
    identity: profile.account,
    clientID: profile.clientID,
    repository: repository,
    exactSHA: baseRun.headSHA
)

var environmentCatalog: GitHubEnvironmentCatalog?
if !deploymentEvidence.deployments.isEmpty,
   option.activityAccess.actions != .unavailable
{
    do {
        environmentCatalog = try await environmentCatalogLoader.environmentCatalog(
            connection: profile.connection,
            identity: profile.account,
            clientID: profile.clientID,
            repository: repository
        )
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

Keep this inside the existing Deployment best-effort block so a Deployment failure performs zero Environment requests.

Do not call the Environment loader from `GitHubActivityProvider` or `loadActivityItems()`.

- [ ] **Step 9: Wire production composition**

In `SchneeBarApp.swift` add:

```swift
private let environmentCatalogService: GitHubEnvironmentCatalogService
```

Initialize with the same session coordinator:

```swift
environmentCatalogService = GitHubEnvironmentCatalogService(
    sessionCoordinator: sessionCoordinator
)
```

Capture it in `applicationDidFinishLaunching`:

```swift
let environmentCatalogService = environmentCatalogService
```

Pass it only to detail loading:

```swift
try await githubRuntimeModel.loadActivityDetail(
    for: item,
    jobService: workflowJobService,
    timelineLoader: deliveryTimelineService,
    deploymentTimelineLoader: deploymentTimelineService,
    environmentCatalogLoader: environmentCatalogService
)
```

Do not pass it to `GitHubActivityProvider`.

- [ ] **Step 10: Verify GREEN**

Run:

```bash
mise exec -- tuist test SchneeBarAppTests -- -skipMacroValidation CODE_SIGNING_ALLOWED=NO
```

Expected: PASS, including all existing detail/Deployment tests.

- [ ] **Step 11: Commit**

```bash
git add Sources/SchneeBarApp/GitHubConnectionsRuntimeModel+ActivityDetail.swift Sources/SchneeBarApp/SchneeBarApp.swift Tests/SchneeBarAppTests/GitHubConnectionsRuntimeModelActivityDetailTests.swift
git commit -m "feat: enrich deployment detail with environments"
```

---

### Task 5: Raise and prove the complete feature-network cap from 11 to 12

**Files:**
- Modify: `Tests/SchneeBarGitHubTests/GitHubDeliveryAndDeploymentRequestBudgetTests.swift`

**Interfaces:**
- Consumes: `GitHubDeliveryTimelineService`, `GitHubDeploymentTimelineService`, `GitHubEnvironmentCatalogService`.
- Produces: a shared-transport network regression proving the feature path is exactly 12 requests at its maximum bounded path.

- [ ] **Step 1: Rename the existing budget test**

Change:

```swift
func completeDeliveryAndDeploymentEvidencePathNeverExceedsElevenFeatureRequests()
```

to:

```swift
func completeDeliveryDeploymentAndEnvironmentEvidencePathUsesTwelveFeatureRequests()
```

Do not change expectations yet.

- [ ] **Step 2: Extend the routing transport with the Environment endpoint**

Add:

```swift
case "/repos/octocat/project/environments":
    json = """
    {
      "total_count":3,
      "environments":[
        {
          "id":301,
          "name":"production",
          "protection_rules":[
            {
              "type":"required_reviewers",
              "prevent_self_review":true,
              "reviewers":[{"type":"User","reviewer":{"id":1,"login":"synthetic"}}]
            },
            {"type":"wait_timer","wait_timer":30}
          ],
          "deployment_branch_policy":{
            "protected_branches":false,
            "custom_branch_policies":true
          },
          "created_at":"2026-09-18T00:00:00Z",
          "updated_at":"2026-09-18T00:01:00Z"
        },
        {
          "id":302,
          "name":"staging",
          "protection_rules":[],
          "deployment_branch_policy":null,
          "created_at":null,
          "updated_at":null
        },
        {
          "id":303,
          "name":"preview",
          "protection_rules":[],
          "created_at":null,
          "updated_at":null
        }
      ]
    }
    """
    statusCode = 200
```

- [ ] **Step 3: Write RED twelve-request assertions**

Instantiate:

```swift
let environmentService = GitHubEnvironmentCatalogService(
    sessionCoordinator: coordinator,
    environmentClient: GitHubEnvironmentClient(transport: transport)
)
```

After the existing seven Delivery requests and four Deployment requests:

```swift
let environmentCatalog = try await environmentService.environmentCatalog(
    connection: connection,
    identity: identity,
    clientID: nil,
    repository: repository
)

#expect(environmentCatalog.environments.count == 3)

let featureRequests = await transport.recordedRequests()
#expect(featureRequests.count == 12)

let environmentRequests = featureRequests.filter {
    $0.url?.path == "/repos/octocat/project/environments"
}
#expect(environmentRequests.count == 1)

let deploymentRequests = featureRequests.filter {
    $0.url?.path.contains("/deployments") == true
}
#expect(deploymentRequests.count == 4)

let correlationRequests = featureRequests.filter {
    $0.url?.path.contains("/deployments") != true
        && $0.url?.path != "/repos/octocat/project/environments"
}
#expect(correlationRequests.count == 7)
```

Also assert:

```swift
#expect(queryValue("per_page", in: try #require(environmentRequests.first)) == "100")
#expect(queryValue("page", in: try #require(environmentRequests.first)) == "1")
```

- [ ] **Step 4: Verify RED**

Run:

```bash
mise exec -- tuist test SchneeBarGitHubTests -- -skipMacroValidation CODE_SIGNING_ALLOWED=NO
```

Expected before Tasks 1/2 are implemented: compile failure for Environment service/client types. When executing this task after Tasks 1/2, first change the expected total from 11 to 12 before invoking Environment loading and observe the assertion fail at 11, then add the Environment call and rerun.

This task's meaningful RED is the network-count mismatch, not merely a missing type.

- [ ] **Step 5: Verify GREEN**

Run the same target.

Expected:

```text
Delivery correlation requests: 7
Deployment enrichment requests: 4
Environment enrichment requests: 1
Total feature requests: 12
```

No session/setup request may be counted as a feature request.

- [ ] **Step 6: Commit**

```bash
git add Tests/SchneeBarGitHubTests/GitHubDeliveryAndDeploymentRequestBudgetTests.swift
git commit -m "test: cap delivery environment enrichment at twelve requests"
```

---

### Task 6: Add deterministic Environment visuals and update the roadmap

**Files:**
- Modify: `Sources/SchneeBarPreviewSupport/ActivityDetailFixtures.swift`
- Modify: `Sources/SchneeBarVisualHarness/SchneeBarVisualHarnessApp.swift`
- Modify: `Sources/SchneeBarVisualSnapshotCLI/main.swift`
- Modify: `docs/DEVELOPMENT_PLAN.md`

**Interfaces:**
- Consumes: existing `ActivityDetailFixtureScenario`, `DeliveryTimelineEvent`.
- Produces six Environment-specific deterministic scenarios rendered in Light and Dark.

- [ ] **Step 1: Add Environment fixture scenarios**

Extend `ActivityDetailFixtureScenario`:

```swift
case environmentProductionProtected = "environment-production-protected"
case environmentStagingProtected = "environment-staging-protected"
case environmentCapabilityUnavailable = "environment-capability-unavailable"
case environmentRequestFailure = "environment-request-failure"
case environmentCatalogTruncatedMatched = "environment-catalog-truncated-matched"
case environmentPartialMatches = "environment-partial-matches"
```

Titles:

```swift
case .environmentProductionProtected:
    "Environment production protected"
case .environmentStagingProtected:
    "Environment staging protected"
case .environmentCapabilityUnavailable:
    "Environment capability unavailable"
case .environmentRequestFailure:
    "Environment request failure"
case .environmentCatalogTruncatedMatched:
    "Environment truncated matched"
case .environmentPartialMatches:
    "Environment partial matches"
```

- [ ] **Step 2: Add deterministic snapshots**

Production protected event:

```swift
DeliveryTimelineEvent(
    id: "github-delivery-deployment:1001",
    kind: .deployment,
    title: "Deployment · production",
    detail: "Succeeded · Production · 2 reviewers · 30m wait · No self-review · Custom branches",
    state: .success,
    destinationURL: URL(string: "https://deploy.example.test/production"),
    occurredAt: Date(timeIntervalSince1970: 1_789_710_300)
)
```

Staging protected:

```swift
DeliveryTimelineEvent(
    id: "github-delivery-deployment:1002",
    kind: .deployment,
    title: "Deployment · staging",
    detail: "Running · Protected branches",
    state: .running,
    destinationURL: URL(string: "https://deploy.example.test/staging"),
    occurredAt: Date(timeIntervalSince1970: 1_789_710_310)
)
```

Capability unavailable and request failure both intentionally reuse the existing unenriched Deployment detail:

```text
Succeeded · Production
```

Truncated matched demonstrates that a page-1 match may still enrich:

```text
Succeeded · Production · 1 reviewer · 1h wait
```

Partial matches use at most three Deployment events:

```text
production -> enriched
staging    -> unchanged
preview    -> enriched
```

All URLs use `example.test`.

- [ ] **Step 3: Register all six scenarios in the Snapshot CLI**

Extend the existing `deliveryScenarios` array:

```swift
.environmentProductionProtected,
.environmentStagingProtected,
.environmentCapabilityUnavailable,
.environmentRequestFailure,
.environmentCatalogTruncatedMatched,
.environmentPartialMatches,
```

The existing loop already renders both appearances:

```swift
for appearance in SnapshotAppearance.allCases {
    try render(
        rootView: activityDetailRoot(
            scenario: scenario,
            appearance: appearance
        ),
        appearance: appearance,
        filename: "activity-detail-\(scenario.rawValue)-\(appearance.rawValue).png",
        outputDirectory: outputDirectory
    )
}
```

Keep the Activity detail width at 340 points.

- [ ] **Step 4: Point Visual Harness default at the richest Environment state**

Change:

```swift
@State private var activityDetailScenario: ActivityDetailFixtureScenario =
    .environmentProductionProtected
```

This makes manual inspection immediately show the new slice.

- [ ] **Step 5: Update `docs/DEVELOPMENT_PLAN.md`**

Under Phase 4 implemented items add:

```markdown
- demand-driven repository Environment enrichment for already-correlated exact-SHA Deployments
- built-in Environment protection summaries for reviewer count, wait timer, self-review prevention, and branch-policy mode
- one-request Environment enrichment cap with a complete explicit-detail Delivery ceiling of 12 feature HTTP requests
- conservative page-1 Environment matching that preserves existing Deployment events on truncation, absence, ambiguity, or technical failure
- Actions-capability-gated Environment detail loading with no background Environment polling
- reviewer-identity and provider-Environment-URL minimization at normalization boundaries
- deterministic Light/Dark Environment protection and fallback fixtures
```

Replace any priority that still says Environment inventory is the next immediate task with:

```markdown
1. Add explicit repository default-branch discovery and standalone Delivery history.
2. Add recovery notifications and persisted Delivery history.
3. Revisit standalone/paginated Environment browsing and custom protection-rule details only if product usage justifies the extra scope.
4. Broaden enterprise validation toward Phase 5 requirements.
5. Only then broaden system widgets or external provider/plugin scope.
```

Keep these deferred:

- paginated Environment inventory;
- custom protection rules;
- custom branch-policy pattern details;
- approval actions;
- reviewer identities.

- [ ] **Step 6: Run focused build/tests before Visual CI**

Run:

```bash
mise exec -- tuist test SchneeBarAppTests -- -skipMacroValidation CODE_SIGNING_ALLOWED=NO
mise exec -- tuist test SchneeBarGitHubActivityProviderTests -- -skipMacroValidation CODE_SIGNING_ALLOWED=NO
```

Expected: PASS.

- [ ] **Step 7: Render local deterministic visuals when a macOS runner/worktree is available**

Run the repository's existing Visual Snapshot CLI command used by `.github/workflows/visual-regression.yml`.

Expected:

- all six new scenarios render;
- both Light and Dark render for each;
- no fixture contains reviewer login/team identity;
- no layout width increase is required.

If execution is connector-only with no local macOS checkout, rely on the PR Visual Regression workflow and inspect its render step/result before the final gate.

- [ ] **Step 8: Commit**

```bash
git add Sources/SchneeBarPreviewSupport/ActivityDetailFixtures.swift Sources/SchneeBarVisualHarness/SchneeBarVisualHarnessApp.swift Sources/SchneeBarVisualSnapshotCLI/main.swift docs/DEVELOPMENT_PLAN.md
git commit -m "test: add environment enrichment visual coverage"
```

---

### Task 7: Run the final exact-head review, security, and integration gate

**Files:**
- No production changes unless review finds a concrete defect.
- Modify PR description/checklist only after fresh evidence exists.

**Interfaces:**
- Consumes: implementation branch final SHA.
- Produces: a review-ready implementation PR stacked on or rebased after PR #51, with exact-head CI / Visual Regression / CodeQL evidence.

- [ ] **Step 1: Perform a scope/security diff review**

Review the full implementation diff and prove all of the following:

```text
No changes to SchneeBarCore.
No Environment request added to GitHubActivityProvider background polling.
No /deployment_protection_rules requests.
No /deployment-branch-policies requests.
No Environment write/update/delete request.
No Environment secret/variable request.
No pending-deployment approval request.
No reviewer identity in normalized public models or UI fixtures.
No provider Environment URL in normalized public models.
No raw SHA added to UI copy.
No private host/repository/environment fixture.
No unpinned third-party GitHub Action.
No pull_request_target.
```

If any item fails, fix it and restart exact-head verification.

- [ ] **Step 2: Re-read the spec acceptance criteria line by line**

Check every acceptance criterion in:

`docs/superpowers/specs/2026-09-20-github-environment-enrichment-design.md`

Map each criterion to:

- a production path;
- a focused test;
- or a verified diff invariant.

Do not mark Task 7 complete from CI status alone.

- [ ] **Step 3: Run the full repository CI on the exact implementation head**

Required workflow:

```text
CI
```

Required result:

```text
Build: success
Test: success
workflow conclusion: success
```

Record the exact head SHA and workflow run ID in the PR body.

- [ ] **Step 4: Run Visual Regression on the same exact head**

Required result:

```text
Render candidate: success
Render PR base: success
Build visual report: success
Upload visual report: success
workflow conclusion: success
```

Verify the run head SHA exactly equals the implementation head from Step 3.

- [ ] **Step 5: Mark the implementation PR Ready for review**

Only after CI + Visual Regression are green and the implementation head has stopped moving.

Changing Draft -> Ready may trigger CodeQL.

- [ ] **Step 6: Run CodeQL on that exact same head**

Required result:

```text
Build for analysis: success
Analyze: success
workflow conclusion: success
```

If CodeQL is skipped because the PR is Draft, do not treat that as success; mark Ready and wait for the non-skipped run.

- [ ] **Step 7: Check review state**

Assert:

```text
unresolved review threads == 0
requested-changes reviews == 0
PR mergeable == true
PR head SHA == verified CI/Visual/CodeQL SHA
```

If the head moves after any check, restart Steps 3-7 for the new SHA.

- [ ] **Step 8: Update the implementation PR verification record**

Add:

```markdown
## Final exact-head gate

Verified implementation head: `69572a619c013273050565a1171fb04ae0644f81`

- CI: success
- Visual Regression: success
- CodeQL: success
- complete feature-network ceiling: 12 HTTP requests
- Environment list ceiling: 1 HTTP request
- background Environment polling: none
- unresolved review threads: 0
- requested-changes reviews: 0
- mergeable: true
```

Replace that example SHA with the real implementation head before posting the final verification record.

- [ ] **Step 9: Integration discipline**

If PR #51 is still open:

- keep this implementation PR stacked on `feat/github-deployment-timeline`;
- do not merge it into `main` before PR #51;
- do not modify PR #51 to absorb this work.

After PR #51 lands:

- rebase or recreate the implementation branch from the resulting `main` only when explicitly executing the integration step;
- rerun the complete exact-head gate after any history/head change.

Do not delete branches without explicit authorization.

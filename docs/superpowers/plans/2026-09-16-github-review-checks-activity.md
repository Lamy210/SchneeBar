# GitHub Review Requests + Checks Activity Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Turn Developer Activity into a bounded priority inbox that combines GitHub Actions, direct Pull Request review requests, and relevant Check Runs without weakening connection isolation, capability gating, or low-idle-overhead behavior.

**Architecture:** `SchneeBarCore` owns provider-neutral activity kind, attention, ordering, and summary semantics. `SchneeBarGitHub` owns authenticated REST clients/services and normalized GitHub models, while `SchneeBarGitHubActivityProvider` owns source scheduling, Workflow evidence, source caches, Check candidate planning, capability preflight, and source-level result accounting. The App runtime composes the services and keeps connection health separate from capability-only blocks; SwiftUI receives only provider-neutral activity plus normalized capability presentation.

**Tech Stack:** Swift 6.3, Swift Testing, Swift Concurrency/actors, SwiftUI, Observation, Tuist 4.203.1, Xcode 26.6, macOS 15+, GitHub REST API, GitHub Actions CI/Visual Regression/CodeQL.

**Spec:** `docs/superpowers/specs/2026-09-16-github-review-checks-activity-design.md`

## Global Constraints

- macOS deployment target remains 15.0.
- Xcode 26.6 / Swift 6.3 remain the production baseline; Xcode 27 / Swift 6.4 remain canary-only.
- Tuist stays pinned to 4.203.1 via mise.
- Domain/Application code remains independent of SwiftUI and AppKit.
- Raw GitHub REST payloads must be normalized before they cross the `SchneeBarGitHub` adapter boundary.
- The session coordinator remains the only credential/session authority; bearer and refresh tokens never enter App/UI state, fixtures, logs, or docs.
- Direct review identity matching uses the connected account's stable GitHub account ID, never login text alone.
- Team review requests are out of scope; repository access must not be used to infer team membership.
- Review polling is one page of at most 100 most-recently-updated open Pull Requests per selected repository poll.
- Check polling is one page of at most 100 Check Runs per candidate ref.
- Per connection / periodic refresh, activity source list requests are capped at 8 Workflow + 4 Review + 4 Check = 16. Session-layer credential refresh traffic is outside this source-list budget.
- Check candidate discovery uses direct-review head SHAs plus recently polled Workflow Run head SHAs, including successful Workflow Runs hidden from the top-level inbox.
- GitHub Actions-owned Check Runs are suppressed only when an equivalent same-repository/same-SHA visible Workflow row exists.
- Capability `.unavailable` blocks that source without making a network request; `.available` and `.unknown` remain requestable.
- Capability-only blocks never downgrade an otherwise healthy GitHub connection to connection-level `.unavailable`.
- A 401/authentication failure from any attempted source remains connection-wide and enters the existing `.authenticationRequired` recovery path.
- Repository monitoring selection gates Workflow, Review, and Check sources consistently.
- Provider reset/disable/selection changes must invalidate stale async work across all three sources.
- Do not add per-source user preferences, team membership discovery, deployment activity, write actions, SQLite persistence, or a generic plugin framework in this change.

## File Structure

### Core

- `Sources/SchneeBarCore/ActivityItem.swift` — add `ActivityKind`, `ActivityAttention`, `updatedAt`, and backward-compatible Codable behavior.
- `Sources/SchneeBarCore/ActivityInboxOrdering.swift` — one reusable provider-neutral comparator for global inbox ordering.
- `Sources/SchneeBarCore/ActivitySummary.swift` — attention-aware counts and non-CI-specific menu-bar summary.
- `Tests/SchneeBarCoreTests/ActivityItemTests.swift` — decoding/default compatibility.
- `Tests/SchneeBarCoreTests/ActivityInboxOrderingTests.swift` — attention/state/time/stable tie-break ordering.
- `Tests/SchneeBarCoreTests/ActivitySummaryTests.swift` — compact summary priority semantics.

### GitHub adapter

- `Sources/SchneeBarGitHub/GitHubPullRequestListClient.swift` — one-page open-PR loader and normalized `GitHubReviewRequest`.
- `Sources/SchneeBarGitHub/GitHubReviewRequestService.swift` — session-authorized `GitHubReviewRequestLoading` service.
- `Sources/SchneeBarGitHub/GitHubCheckRunClient.swift` — one-page Check Run loader with Check-specific status/conclusion enums.
- `Sources/SchneeBarGitHub/GitHubCheckRunService.swift` — session-authorized `GitHubCheckRunLoading` service.
- `Tests/SchneeBarGitHubTests/GitHubPullRequestListClientTests.swift` — request shape, reviewer IDs, bounds, trusted URL, failures.
- `Tests/SchneeBarGitHubTests/GitHubReviewRequestServiceTests.swift` — session authorization forwarding.
- `Tests/SchneeBarGitHubTests/GitHubCheckRunClientTests.swift` — status/conclusion normalization, bounds, trusted URL, failures.
- `Tests/SchneeBarGitHubTests/GitHubCheckRunServiceTests.swift` — session authorization forwarding.

### GitHub Activity provider

- `Sources/SchneeBarGitHubActivityProvider/GitHubReviewRequestActivityMapper.swift` — direct-review filtering and Activity mapping.
- `Sources/SchneeBarGitHubActivityProvider/GitHubCheckRunActivityMapper.swift` — Check visibility/classification and GitHub Actions duplicate suppression.
- `Sources/SchneeBarGitHubActivityProvider/GitHubWorkflowEvidence.swift` — provider-private Workflow SHA evidence from all polled runs.
- `Sources/SchneeBarGitHubActivityProvider/GitHubCheckCandidatePlanner.swift` — deterministic review-first / workflow-second SHA selection.
- `Sources/SchneeBarGitHubActivityProvider/GitHubActivitySurfaceResult.swift` — formal source identity, target failure, and source accounting contract.
- `Sources/SchneeBarGitHubActivityProvider/GitHubActivityProvider.swift` — multi-source scheduling/caching/generation/capability integration while retaining hot/cold Workflow behavior.
- `Tests/SchneeBarGitHubActivityProviderTests/GitHubReviewRequestActivityMapperTests.swift` — stable-ID filtering and review Activity semantics.
- `Tests/SchneeBarGitHubActivityProviderTests/GitHubCheckRunActivityMapperTests.swift` — failure/activity mapping and same-SHA duplicate policy.
- `Tests/SchneeBarGitHubActivityProviderTests/GitHubCheckCandidatePlannerTests.swift` — hidden-success evidence, dedup, 2-per-repo/4-total budget.
- `Tests/SchneeBarGitHubActivityProviderTests/GitHubActivityProviderMultiSourceTests.swift` — capability gates, source accounting, cache clearing, request budgets, partial failures, stale generations.

### Runtime / presentation

- `Sources/SchneeBarApp/SchneeBarApp.swift` — compose Review and Check services into the provider.
- `Sources/SchneeBarApp/GitHubConnectionsRuntimeModel.swift` — consume formal source results; separate connection health from capability-only blocks; use Core ordering.
- `Sources/SchneeBarGitHubFeature/GitHubConnectionManagementView.swift` — three-surface capability model and compact unavailable/unverified badges.
- `Sources/SchneeBarActivityFeature/ActivityPopoverView.swift` — kind-aware inspect affordance/help and generalized activity summary presentation.
- `Tests/SchneeBarAppTests/GitHubConnectionsRuntimeModelActivityTests.swift` — aggregate ordering and connection-health policy.
- `Tests/SchneeBarActivityFeatureTests/ActivityPopoverBehaviorTests.swift` — kind-aware local-detail affordance where testable without snapshot coupling.

### Deterministic UI / docs

- `Sources/SchneeBarPreviewSupport/ActivityFixtures.swift` — mixed Review/Check/Workflow fictional inbox fixtures.
- `Sources/SchneeBarPreviewSupport/GitHubConnectionFixtures.swift` — mixed capability-management fixtures.
- `Sources/SchneeBarVisualHarness/SchneeBarVisualHarnessApp.swift` — new activity/capability scenes.
- `Sources/SchneeBarVisualSnapshotCLI/main.swift` — register deterministic snapshots.
- `docs/DEVELOPMENT_PLAN.md` — mark Review Requests, Checks, and priority Inbox semantics implemented only after final verification.

## Execution Prerequisite

Merge the approved design/plan documentation branch into `main`, then create `feat/github-review-checks-activity` from that exact `main`. Do not implement production code on the documentation branch.

```bash
# Repository workflow
# 1. Merge docs/github-review-checks-activity-design into main.
# 2. Create feat/github-review-checks-activity from the resulting main SHA.
# 3. Execute Tasks 1-9 in order.
```

---

### Task 1: Add provider-neutral Inbox semantics and backward-compatible Activity decoding

**Files:**
- Modify: `Sources/SchneeBarCore/ActivityItem.swift`
- Create: `Sources/SchneeBarCore/ActivityInboxOrdering.swift`
- Modify: `Sources/SchneeBarCore/ActivitySummary.swift`
- Create or modify: `Tests/SchneeBarCoreTests/ActivityItemTests.swift`
- Create: `Tests/SchneeBarCoreTests/ActivityInboxOrderingTests.swift`
- Modify: `Tests/SchneeBarCoreTests/ActivitySummaryTests.swift`

**Interfaces:**
- Produces:

```swift
public enum ActivityKind: String, Codable, CaseIterable, Sendable {
    case workflowRun
    case reviewRequest
    case checkRun
}

public enum ActivityAttention: String, Codable, CaseIterable, Sendable {
    case actionRequired
    case needsAttention
    case active
    case informational
}

public struct ActivityInboxOrdering: Sendable {
    public init() {}
    public func areInIncreasingOrder(_ lhs: ActivityItem, _ rhs: ActivityItem) -> Bool
}
```

- `ActivityItem` keeps its current fields and adds:

```swift
public let kind: ActivityKind
public let attention: ActivityAttention
public let updatedAt: Date?
```

- Its initializer defaults preserve old call sites:

```swift
public init(
    id: String,
    repository: String,
    context: String,
    detail: String,
    state: ActivityState,
    destinationURL: URL? = nil,
    kind: ActivityKind = .workflowRun,
    attention: ActivityAttention? = nil,
    updatedAt: Date? = nil
)
```

When `attention == nil`, derive `.failed -> .needsAttention`, `.running/.waiting -> .active`, `.success -> .informational`.

- [ ] **Step 1: Write RED tests for old Codable payloads and initializer defaults**

Use Swift Testing and a fixed JSON payload that predates the new fields:

```swift
import Foundation
import SchneeBarCore
import Testing

@Test
func decodesLegacyActivityItemWithWorkflowDefaults() throws {
    let json = #"{"id":"legacy-1","repository":"snow/app","context":"main · CI","detail":"Running","state":"running","destinationURL":null}"#
    let item = try JSONDecoder().decode(ActivityItem.self, from: Data(json.utf8))

    #expect(item.kind == .workflowRun)
    #expect(item.attention == .active)
    #expect(item.updatedAt == nil)
}

@Test
func initializerDerivesAttentionFromStateWhenOmitted() {
    #expect(ActivityItem(id: "f", repository: "a/b", context: "CI", detail: "Failed", state: .failed).attention == .needsAttention)
    #expect(ActivityItem(id: "r", repository: "a/b", context: "CI", detail: "Running", state: .running).attention == .active)
    #expect(ActivityItem(id: "s", repository: "a/b", context: "CI", detail: "Done", state: .success).attention == .informational)
}
```

- [ ] **Step 2: Run Core tests and verify RED**

Run:

```bash
tuist test SchneeBarCoreTests -- -skipMacroValidation CODE_SIGNING_ALLOWED=NO
```

Expected: compile/test failure because `ActivityKind`, `ActivityAttention`, and new properties do not exist.

- [ ] **Step 3: Implement explicit Codable compatibility in `ActivityItem`**

Do not rely on synthesized `Codable`. Add `CodingKeys`, explicit `init(from:)`, and `encode(to:)`. Decode the old fields first, then use `decodeIfPresent` for `kind`, `attention`, and `updatedAt`; derive attention from decoded `state` when absent.

Use one private helper shared by initializer and decoder:

```swift
private static func defaultAttention(for state: ActivityState) -> ActivityAttention {
    switch state {
    case .failed: .needsAttention
    case .running, .waiting: .active
    case .success: .informational
    }
}
```

- [ ] **Step 4: Write RED ordering tests**

Create fixed timestamps and assert the exact order:

```swift
@Test
func ordersByAttentionThenStateThenRecencyThenStableFields() {
    let now = Date(timeIntervalSince1970: 2_000)
    let older = Date(timeIntervalSince1970: 1_000)
    let items = [
        ActivityItem(id: "wait", repository: "snow/b", context: "CI", detail: "Waiting", state: .waiting, kind: .workflowRun, attention: .active, updatedAt: now),
        ActivityItem(id: "run", repository: "snow/a", context: "CI", detail: "Running", state: .running, kind: .workflowRun, attention: .active, updatedAt: older),
        ActivityItem(id: "fail", repository: "snow/a", context: "Check", detail: "Failed", state: .failed, kind: .checkRun, attention: .needsAttention, updatedAt: now),
        ActivityItem(id: "review", repository: "snow/a", context: "PR #7", detail: "Review requested", state: .waiting, kind: .reviewRequest, attention: .actionRequired, updatedAt: older),
    ]

    let sorted = items.sorted(by: ActivityInboxOrdering().areInIncreasingOrder)
    #expect(sorted.map(\.id) == ["review", "fail", "run", "wait"])
}
```

Also add a test proving dated items precede undated items and `repository -> kind.rawValue -> id` breaks final ties deterministically.

- [ ] **Step 5: Implement `ActivityInboxOrdering`**

Use explicit rank functions rather than enum declaration order:

```swift
private func attentionRank(_ attention: ActivityAttention) -> Int {
    switch attention {
    case .actionRequired: 0
    case .needsAttention: 1
    case .active: 2
    case .informational: 3
    }
}

private func stateRank(_ state: ActivityState) -> Int {
    switch state {
    case .failed: 0
    case .running: 1
    case .waiting: 2
    case .success: 3
    }
}
```

Then compare attention rank, state rank, optional `updatedAt`, repository, `kind.rawValue`, and ID in that order.

- [ ] **Step 6: Write RED summary tests and implement generalized summary**

Add:

```swift
@Test
func actionRequiredSummaryOutranksFailedAndRunning() {
    let items = [
        ActivityItem(id: "review", repository: "a/b", context: "PR #1", detail: "Review requested", state: .waiting, kind: .reviewRequest, attention: .actionRequired),
        ActivityItem(id: "failed", repository: "a/b", context: "Check", detail: "Failed", state: .failed, kind: .checkRun, attention: .needsAttention),
    ]
    let summary = ActivitySummary(items: items)
    #expect(summary.actionRequired == 1)
    #expect(summary.needsAttention == 1)
    #expect(summary.menuBarLabel.contains("1"))
    #expect(!summary.menuBarLabel.hasPrefix("CI"))
}
```

Implement `actionRequired` and `needsAttention` counts. Change the compact label to activity-neutral copy with priority `actionRequired -> needsAttention/failed -> running -> waiting -> clear`; keep strings short and deterministic so Visual Regression can lock them later.

- [ ] **Step 7: Run Core tests and commit**

Run:

```bash
tuist test SchneeBarCoreTests -- -skipMacroValidation CODE_SIGNING_ALLOWED=NO
```

Expected: PASS.

Commit:

```bash
git add Sources/SchneeBarCore Tests/SchneeBarCoreTests
git commit -m "feat: add activity inbox semantics"
```

---

### Task 2: Add bounded direct Review Request client and authenticated service

**Files:**
- Create: `Sources/SchneeBarGitHub/GitHubPullRequestListClient.swift`
- Create: `Sources/SchneeBarGitHub/GitHubReviewRequestService.swift`
- Create: `Tests/SchneeBarGitHubTests/GitHubPullRequestListClientTests.swift`
- Create: `Tests/SchneeBarGitHubTests/GitHubReviewRequestServiceTests.swift`

**Interfaces:**
- Produces:

```swift
public struct GitHubReviewRequest: Equatable, Sendable {
    public let number: Int
    public let title: String
    public let headSHA: String
    public let isDraft: Bool
    public let updatedAt: Date
    public let requestedReviewerIDs: Set<String>
    public let webURL: URL
}

public enum GitHubPullRequestListClientError: Error, Equatable, Sendable {
    case invalidCredential
    case invalidRepository
    case invalidResponse
    case httpStatus(Int)
}

public protocol GitHubReviewRequestLoading: Sendable {
    func reviewRequests(
        connection: GitHubConnection,
        identity: GitHubAccountIdentity,
        clientID: String?,
        repository: GitHubRepositoryAccess
    ) async throws -> [GitHubReviewRequest]
}
```

- `GitHubPullRequestListClient.openPullRequests(...)` always requests `state=open&sort=updated&direction=desc&per_page=100` and never follows pagination for this periodic source.

- [ ] **Step 1: Write RED client request/normalization tests**

Use a recording `GitHubHTTPTransport` and a response with two PRs. Assert:

```swift
@Test
func loadsOnePageOfRecentOpenPullRequestsAndNormalizesReviewerIDs() async throws {
    let transport = RecordingGitHubTransport(responseJSON: reviewListJSON)
    let client = GitHubPullRequestListClient(transport: transport)
    let requests = try await client.openPullRequests(
        repository: try reviewRepository(),
        connection: try reviewConnection(),
        credential: GitHubCredential(accessToken: "test-token")
    )

    #expect(requests.count == 2)
    #expect(requests[0].requestedReviewerIDs == ["42", "99"])
    #expect(requests[0].headSHA == "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa")

    let request = try #require(await transport.recordedRequests().first)
    let components = try #require(URLComponents(url: request.url!, resolvingAgainstBaseURL: false))
    let query = Dictionary(uniqueKeysWithValues: (components.queryItems ?? []).map { ($0.name, $0.value ?? "") })
    #expect(query["state"] == "open")
    #expect(query["sort"] == "updated")
    #expect(query["direction"] == "desc")
    #expect(query["per_page"] == "100")
}
```

The fixture PR JSON must include `number`, `title`, `draft`, `updated_at`, `head.sha`, and `requested_reviewers[{id,login}]`.

- [ ] **Step 2: Add RED URL-trust and error tests**

Test that a malicious/different `html_url` in the payload is ignored and the returned URL equals the trusted connection endpoint path `/{owner}/{repo}/pull/{number}`. Add tests for blank credential, invalid repository owner/name, malformed required payload, HTTP 401, 403, and 404.

- [ ] **Step 3: Run GitHub tests and verify RED**

Run:

```bash
tuist test SchneeBarGitHubTests -- -skipMacroValidation CODE_SIGNING_ALLOWED=NO
```

Expected: compile failure because the client/types do not exist.

- [ ] **Step 4: Implement `GitHubPullRequestListClient` minimally**

Follow the existing `GitHubPullRequestMetadataClient` conventions:

```swift
let url = endpoints.restBaseURL
    .appendingPathComponent("repos", isDirectory: true)
    .appendingPathComponent(repository.ownerLogin, isDirectory: true)
    .appendingPathComponent(repository.name, isDirectory: true)
    .appendingPathComponent("pulls", isDirectory: false)
```

Build query items for the fixed one-page policy, send `Accept: application/vnd.github+json`, bearer auth, and current REST version for GitHub.com/GHE.com. Normalize reviewer IDs with `String(reviewer.id)` and reconstruct `webURL` from `endpoints.webBaseURL` rather than payload `html_url`.

- [ ] **Step 5: Write RED authenticated service test**

Use a coordinator/store fixture containing an authorized credential and a recording transport. Verify `GitHubReviewRequestService.reviewRequests` calls the client with a credential obtained through `sessionCoordinator.authorizedCredential(connection:identity:clientID:)`, including refresh behavior already owned by the coordinator.

- [ ] **Step 6: Implement service and run tests**

```swift
public struct GitHubReviewRequestService: GitHubReviewRequestLoading, Sendable {
    private let sessionCoordinator: GitHubConnectionSessionCoordinator
    private let client: GitHubPullRequestListClient

    public init(
        sessionCoordinator: GitHubConnectionSessionCoordinator,
        client: GitHubPullRequestListClient = GitHubPullRequestListClient()
    ) {
        self.sessionCoordinator = sessionCoordinator
        self.client = client
    }

    public func reviewRequests(
        connection: GitHubConnection,
        identity: GitHubAccountIdentity,
        clientID: String?,
        repository: GitHubRepositoryAccess
    ) async throws -> [GitHubReviewRequest] {
        let credential = try await sessionCoordinator.authorizedCredential(
            connection: connection,
            identity: identity,
            clientID: clientID
        )
        return try await client.openPullRequests(
            repository: repository,
            connection: connection,
            credential: credential
        )
    }
}
```

Run:

```bash
tuist test SchneeBarGitHubTests -- -skipMacroValidation CODE_SIGNING_ALLOWED=NO
```

Expected: PASS.

- [ ] **Step 7: Commit**

```bash
git add Sources/SchneeBarGitHub/GitHubPullRequestListClient.swift Sources/SchneeBarGitHub/GitHubReviewRequestService.swift Tests/SchneeBarGitHubTests/GitHubPullRequestListClientTests.swift Tests/SchneeBarGitHubTests/GitHubReviewRequestServiceTests.swift
git commit -m "feat: load GitHub review requests"
```

---

### Task 3: Map direct review requests into action-required Activity items

**Files:**
- Create: `Sources/SchneeBarGitHubActivityProvider/GitHubReviewRequestActivityMapper.swift`
- Create: `Tests/SchneeBarGitHubActivityProviderTests/GitHubReviewRequestActivityMapperTests.swift`

**Interfaces:**
- Consumes: `GitHubReviewRequest`, `GitHubAccountIdentity`, `GitHubRepositoryAccess`, `ActivityItem`.
- Produces:

```swift
public struct GitHubReviewRequestActivityMapper: Sendable {
    public init() {}

    public func visibleRequests(
        requests: [GitHubReviewRequest],
        identity: GitHubAccountIdentity,
        repository: GitHubRepositoryAccess
    ) -> [GitHubReviewRequest]

    public func activityItem(
        request: GitHubReviewRequest,
        repository: GitHubRepositoryAccess
    ) -> ActivityItem
}
```

- [ ] **Step 1: Write RED stable-identity and team-exclusion tests**

```swift
@Test
func emitsOnlyRequestsContainingConnectedStableAccountID() throws {
    let mapper = GitHubReviewRequestActivityMapper()
    let identity = GitHubAccountIdentity(id: "42", login: "renamed-user")
    let requests = [
        reviewRequest(number: 7, reviewerIDs: ["42"]),
        reviewRequest(number: 8, reviewerIDs: ["99"]),
        reviewRequest(number: 9, reviewerIDs: []),
    ]

    let visible = mapper.visibleRequests(
        requests: requests,
        identity: identity,
        repository: try reviewRepository()
    )
    #expect(visible.map(\.number) == [7])
}
```

The empty-reviewer fixture represents team-only/no-direct-user evidence and must not be emitted. Add a renamed-login case showing ID `42` still matches even when login text differs.

- [ ] **Step 2: Write RED Activity mapping test**

Assert exact provider-neutral fields:

```swift
let item = mapper.activityItem(request: request, repository: repository)
#expect(item.id == "github-review:\(repository.id):\(request.number)")
#expect(item.kind == .reviewRequest)
#expect(item.attention == .actionRequired)
#expect(item.state == .waiting)
#expect(item.context == "PR #\(request.number)")
#expect(item.updatedAt == request.updatedAt)
#expect(item.destinationURL == request.webURL)
```

- [ ] **Step 3: Run provider tests and verify RED**

```bash
tuist test SchneeBarGitHubActivityProviderTests -- -skipMacroValidation CODE_SIGNING_ALLOWED=NO
```

Expected: compile failure because mapper does not exist.

- [ ] **Step 4: Implement mapper and deterministic ordering**

`visibleRequests` filters only stable IDs and sorts newest `updatedAt` first, then PR number ascending for deterministic ties. `activityItem.detail` should be concise and title-bearing, e.g. `"Review requested · \(request.title)"`.

- [ ] **Step 5: Run tests and commit**

```bash
tuist test SchneeBarGitHubActivityProviderTests -- -skipMacroValidation CODE_SIGNING_ALLOWED=NO
git add Sources/SchneeBarGitHubActivityProvider/GitHubReviewRequestActivityMapper.swift Tests/SchneeBarGitHubActivityProviderTests/GitHubReviewRequestActivityMapperTests.swift
git commit -m "feat: map GitHub review activity"
```

---

### Task 4: Add bounded Check Run client and authenticated service with Check-specific enums

**Files:**
- Create: `Sources/SchneeBarGitHub/GitHubCheckRunClient.swift`
- Create: `Sources/SchneeBarGitHub/GitHubCheckRunService.swift`
- Create: `Tests/SchneeBarGitHubTests/GitHubCheckRunClientTests.swift`
- Create: `Tests/SchneeBarGitHubTests/GitHubCheckRunServiceTests.swift`

**Interfaces:**
- Produces:

```swift
public enum GitHubCheckRunStatus: Equatable, Sendable {
    case queued
    case inProgress
    case completed
    case waiting
    case requested
    case pending
    case unknown(String)
}

public enum GitHubCheckRunConclusion: Equatable, Sendable {
    case actionRequired
    case cancelled
    case failure
    case neutral
    case success
    case skipped
    case stale
    case timedOut
    case unknown(String)
}

public struct GitHubCheckRun: Equatable, Sendable {
    public let id: Int64
    public let name: String
    public let status: GitHubCheckRunStatus
    public let conclusion: GitHubCheckRunConclusion?
    public let appSlug: String?
    public let headSHA: String
    public let startedAt: Date?
    public let completedAt: Date?
    public let webURL: URL
}

public protocol GitHubCheckRunLoading: Sendable {
    func checkRuns(
        connection: GitHubConnection,
        identity: GitHubAccountIdentity,
        clientID: String?,
        repository: GitHubRepositoryAccess,
        headSHA: String
    ) async throws -> [GitHubCheckRun]
}
```

`webURL` is a trusted repository commit/checks destination reconstructed by the client; arbitrary third-party `details_url` is not exposed as navigation.

- [ ] **Step 1: Write RED status/conclusion normalization tests**

Create table-driven tests for all known REST values and unknown preservation. Include:

```swift
@Test
func startupFailureIsNotKnownCheckConclusion() async throws {
    let run = try await loadSingleCheck(conclusion: "startup_failure")
    #expect(run.conclusion == .unknown("startup_failure"))
}
```

Known conclusions are exactly `action_required`, `cancelled`, `failure`, `neutral`, `success`, `skipped`, `stale`, `timed_out`.

- [ ] **Step 2: Write RED bounded-request and trusted-URL tests**

Assert the request path is `/repos/{owner}/{repo}/commits/{sha}/check-runs`, `per_page=100`, only one HTTP request is made, and a payload `details_url` on another domain is ignored. Assert returned `webURL` is constructed under the trusted repository URL for the same SHA.

- [ ] **Step 3: Add RED validation/error tests**

Cover blank credential, invalid repository identity, blank/malformed SHA, malformed required response, and HTTP 401/403/404. Preserve unknown status/conclusion strings rather than rejecting otherwise valid payloads.

- [ ] **Step 4: Run GitHub tests and verify RED**

```bash
tuist test SchneeBarGitHubTests -- -skipMacroValidation CODE_SIGNING_ALLOWED=NO
```

Expected: compile failure because Check types/client do not exist.

- [ ] **Step 5: Implement client with one-page policy**

Use the same headers/API-version policy as other clients. Decode only `check_runs`, normalize `app.slug`, and parse optional timestamps with the existing ISO-8601 approach. Do not follow Link pagination.

- [ ] **Step 6: Write RED service test and implement `GitHubCheckRunService`**

The service mirrors `GitHubWorkflowRunService`: obtain `authorizedCredential` from the session coordinator, then call the client. Verify the credential never appears in the public return model.

- [ ] **Step 7: Run tests and commit**

```bash
tuist test SchneeBarGitHubTests -- -skipMacroValidation CODE_SIGNING_ALLOWED=NO
git add Sources/SchneeBarGitHub/GitHubCheckRunClient.swift Sources/SchneeBarGitHub/GitHubCheckRunService.swift Tests/SchneeBarGitHubTests/GitHubCheckRunClientTests.swift Tests/SchneeBarGitHubTests/GitHubCheckRunServiceTests.swift
git commit -m "feat: load GitHub check runs"
```

---

### Task 5: Add Workflow evidence, Check candidate planning, and Check Activity mapping

**Files:**
- Create: `Sources/SchneeBarGitHubActivityProvider/GitHubWorkflowEvidence.swift`
- Create: `Sources/SchneeBarGitHubActivityProvider/GitHubCheckCandidatePlanner.swift`
- Create: `Sources/SchneeBarGitHubActivityProvider/GitHubCheckRunActivityMapper.swift`
- Create: `Tests/SchneeBarGitHubActivityProviderTests/GitHubCheckCandidatePlannerTests.swift`
- Create: `Tests/SchneeBarGitHubActivityProviderTests/GitHubCheckRunActivityMapperTests.swift`

**Interfaces:**
- Produces provider-private/`internal` evidence:

```swift
struct GitHubWorkflowEvidence: Equatable, Sendable {
    let repositoryID: Int64
    let headSHA: String
    let classification: GitHubWorkflowActivityClassification
    let updatedAt: Date
    let isVisible: Bool
}
```

- Produces planner:

```swift
struct GitHubCheckCandidate: Equatable, Sendable {
    let repositoryID: Int64
    let headSHA: String
}

struct GitHubCheckCandidatePlanner: Sendable {
    func candidates(
        repositories: [GitHubRepositoryAccess],
        reviewRequestsByRepositoryID: [Int64: [GitHubReviewRequest]],
        workflowEvidenceByRepositoryID: [Int64: [GitHubWorkflowEvidence]],
        maximumTotal: Int,
        maximumPerRepository: Int
    ) -> [GitHubCheckCandidate]
}
```

- Produces Check mapper:

```swift
public struct GitHubCheckRunActivityMapper: Sendable {
    public init() {}

    public func visibleActivities(
        checks: [GitHubCheckRun],
        repository: GitHubRepositoryAccess,
        visibleWorkflowEvidence: [GitHubWorkflowEvidence]
    ) -> [ActivityItem]
}
```

- [ ] **Step 1: Write RED candidate tests for review-first ordering and hidden-success Workflow evidence**

```swift
@Test
func reviewSHAWinsAndHiddenSuccessfulWorkflowStillSeedsChecks() throws {
    let planner = GitHubCheckCandidatePlanner()
    let repository = try repository(id: 10, name: "snow/app")
    let candidates = planner.candidates(
        repositories: [repository],
        reviewRequestsByRepositoryID: [10: [reviewRequest(number: 5, headSHA: "review-sha", updatedAt: date(300))]],
        workflowEvidenceByRepositoryID: [10: [
            GitHubWorkflowEvidence(repositoryID: 10, headSHA: "success-sha", classification: .success, updatedAt: date(200), isVisible: false),
        ]],
        maximumTotal: 4,
        maximumPerRepository: 2
    )

    #expect(candidates.map(\.headSHA) == ["review-sha", "success-sha"])
}
```

Add dedup test when review and Workflow evidence share the same SHA, maximum-two-per-repository, maximum-four-total across repositories, and deterministic repository order.

- [ ] **Step 2: Implement candidate planner**

For each repository, sort direct reviews by `updatedAt desc`, then Workflow evidence by classification rank (`failed`, `running`, `waiting`, `success`, `ignored`) and `updatedAt desc`. Deduplicate SHA while preserving first occurrence. Enforce per-repository limit before global total limit.

- [ ] **Step 3: Write RED Check mapping tests**

Cover:

```swift
#expect(map(check(status: .completed, conclusion: .failure)).state == .failed)
#expect(map(check(status: .completed, conclusion: .failure)).attention == .needsAttention)
#expect(map(check(status: .inProgress, conclusion: nil)).state == .running)
#expect(map(check(status: .queued, conclusion: nil)).state == .waiting)
```

Also assert success/neutral/skipped/cancelled/stale are omitted by `visibleActivities`.

- [ ] **Step 4: Write RED GitHub Actions duplicate tests**

Use a Check with `appSlug == "github-actions"` and same SHA as visible Workflow evidence; assert it is suppressed. Then change evidence to `isVisible == false` and assert the Check remains visible. Add an external Check (`appSlug == "codecov"`) and assert it remains visible even when same-SHA Workflow evidence is visible.

- [ ] **Step 5: Implement mapper**

Use IDs `github-check:{repositoryID}:{checkID}`, `kind = .checkRun`, trusted `check.webURL`, `updatedAt = completedAt ?? startedAt`, and concise context/detail based on Check name and normalized state.

- [ ] **Step 6: Run provider tests and commit**

```bash
tuist test SchneeBarGitHubActivityProviderTests -- -skipMacroValidation CODE_SIGNING_ALLOWED=NO
git add Sources/SchneeBarGitHubActivityProvider/GitHubWorkflowEvidence.swift Sources/SchneeBarGitHubActivityProvider/GitHubCheckCandidatePlanner.swift Sources/SchneeBarGitHubActivityProvider/GitHubCheckRunActivityMapper.swift Tests/SchneeBarGitHubActivityProviderTests/GitHubCheckCandidatePlannerTests.swift Tests/SchneeBarGitHubActivityProviderTests/GitHubCheckRunActivityMapperTests.swift
git commit -m "feat: plan GitHub check activity"
```

---

### Task 6: Introduce formal source results and integrate bounded multi-source scheduling into `GitHubActivityProvider`

**Files:**
- Create: `Sources/SchneeBarGitHubActivityProvider/GitHubActivitySurfaceResult.swift`
- Modify: `Sources/SchneeBarGitHubActivityProvider/GitHubActivityProvider.swift`
- Create: `Tests/SchneeBarGitHubActivityProviderTests/GitHubActivityProviderMultiSourceTests.swift`
- Modify existing provider test fixtures that construct `GitHubActivityProvider`.

**Interfaces:**
- Produces:

```swift
public enum GitHubActivitySurface: String, CaseIterable, Hashable, Sendable {
    case workflows
    case reviewRequests
    case checks
}

public struct GitHubActivityTargetFailure: Equatable, Sendable {
    public let surface: GitHubActivitySurface
    public let repositoryID: Int64
    public let repositoryFullName: String
    public let reason: GitHubRepositoryActivityFailureReason
}

public struct GitHubActivitySurfaceResult: Equatable, Sendable {
    public let surface: GitHubActivitySurface
    public let items: [ActivityItem]
    public let failures: [GitHubActivityTargetFailure]
    public let successfulTargetCount: Int
    public let attemptedTargetCount: Int
    public let blockedTargetCount: Int
}
```

- Evolve aggregate result to retain source identity:

```swift
public struct GitHubActivityLoadResult: Equatable, Sendable {
    public let items: [ActivityItem]
    public let surfaces: [GitHubActivitySurface: GitHubActivitySurfaceResult]

    public var failures: [GitHubActivityTargetFailure] {
        surfaces.values.flatMap(\.failures)
    }

    public var successfulTargetCount: Int {
        surfaces.values.reduce(0) { $0 + $1.successfulTargetCount }
    }

    public var attemptedTargetCount: Int {
        surfaces.values.reduce(0) { $0 + $1.attemptedTargetCount }
    }

    public var blockedTargetCount: Int {
        surfaces.values.reduce(0) { $0 + $1.blockedTargetCount }
    }
}
```

- Provider initializer becomes explicit about all loaders:

```swift
public init(
    workflowRunLoader: any GitHubWorkflowRunLoading,
    reviewRequestLoader: any GitHubReviewRequestLoading,
    checkRunLoader: any GitHubCheckRunLoading,
    activityMapper: GitHubWorkflowActivityMapper = GitHubWorkflowActivityMapper(),
    reviewMapper: GitHubReviewRequestActivityMapper = GitHubReviewRequestActivityMapper(),
    checkMapper: GitHubCheckRunActivityMapper = GitHubCheckRunActivityMapper(),
    maximumConcurrentRepositories: Int = 4,
    perRepositoryRunLimit: Int = 20,
    maximumRepositoriesPerRefresh: Int = 8,
    minimumColdRepositoriesPerRefresh: Int = 2,
    maximumReviewRepositoriesPerRefresh: Int = 4,
    minimumColdReviewRepositoriesPerRefresh: Int = 1,
    maximumCheckRefsPerRefresh: Int = 4,
    maximumCheckRefsPerRepository: Int = 2,
    now: @escaping @Sendable () -> Date = { .now }
)
```

- [ ] **Step 1: Add RED source-result tests**

Construct a result with Workflow success, Review forbidden, and Checks capability-blocked for one repository. Assert source identity and counts remain separate; no repository-only flattening is allowed.

- [ ] **Step 2: Add loader stubs with call recording**

Create actor stubs in `GitHubActivityProviderMultiSourceTests.swift`:

```swift
private actor ReviewLoaderStub: GitHubReviewRequestLoading {
    private(set) var calls: [(UUID, Int64)] = []
    var responses: [Int64: Result<[GitHubReviewRequest], Error>]
    // reviewRequests(...) records (connection.id, repository.id) then returns/throws.
}

private actor CheckLoaderStub: GitHubCheckRunLoading {
    private(set) var calls: [(UUID, Int64, String)] = []
    var responses: [String: Result<[GitHubCheckRun], Error>]
    // checkRuns(...) records connection/repository/SHA then returns/throws.
}
```

Keep the existing Workflow loader stub but make its run fixtures include both visible failures/running runs and successful hidden runs with `headSHA`.

- [ ] **Step 3: Write RED capability-gate tests**

Test `.pullRequests == .unavailable(.missingPermission)` yields zero Review loader calls and Review `blockedTargetCount > 0`. Test `.checks == .unavailable` yields zero Check calls. Test `.unknown(...)` still calls the corresponding loader.

- [ ] **Step 4: Write RED hard-budget and cold-review fairness tests**

With more than 8 eligible repositories and visible/cached candidates, assert per refresh:

```swift
#expect(await workflowLoader.callCount() <= 8)
#expect(await reviewLoader.callCount() <= 4)
#expect(await checkLoader.callCount() <= 4)
#expect(await workflowLoader.callCount() + reviewLoader.callCount() + checkLoader.callCount() <= 16)
```

Across consecutive refreshes, assert at least one previously unpolled Review repository advances even when another Review repository stays hot.

- [ ] **Step 5: Write RED hidden-success Check-discovery regression**

Configure one repository with a successful Workflow Run at SHA `abc`, no direct review, and an external failed Check for `abc`. Assert returned Activity includes the external Check even though the successful Workflow itself is absent from `items`.

- [ ] **Step 6: Write RED same-SHA duplicate and fallback tests**

Case A: visible failed/running Workflow at SHA `abc` plus `github-actions` Check at `abc` -> only Workflow row appears. Case B: hidden successful Workflow evidence at `abc` plus failed `github-actions` Check -> Check row appears. Case C: Workflow request fails but cached evidence/candidate exists and Check succeeds -> Check row is preserved as fallback.

- [ ] **Step 7: Write RED partial-failure/cache-clearing tests**

Assert Review failure does not erase current Workflow/Check items. Assert a later successful empty Review response removes previously cached Review items. Assert a later successful empty Check response removes cached Check items for that SHA. Assert repository deselection prunes Workflow evidence and all three source caches.

- [ ] **Step 8: Write RED authentication and stale-generation tests**

A 401 from any attempted loader must produce an `.authenticationRequired` failure reason tagged with the correct surface. During an in-flight multi-source refresh, call `reset(connectionID:)`, then release the loader; assert stale completion does not repopulate any source cache/evidence.

- [ ] **Step 9: Implement formal result model and provider state**

Add source caches:

```swift
private var cachedWorkflowActivities: [RepositoryPollKey: [GitHubWorkflowActivity]] = [:]
private var workflowEvidence: [RepositoryPollKey: [GitHubWorkflowEvidence]] = [:]
private var cachedReviewRequests: [RepositoryPollKey: [GitHubReviewRequest]] = [:]
private var cachedCheckActivities: [CheckPollKey: [ActivityItem]] = [:]
private var reviewPollState: [RepositoryPollKey: RepositoryPollState] = [:]
```

Use a `CheckPollKey(connectionID:repositoryID:headSHA:)`. `reset` and pruning must clear each map consistently.

- [ ] **Step 10: Implement Workflow + Review phase, then demand-driven Check phase**

Workflow and Review repository loads may execute concurrently under their respective concurrency/budget limits. For each successful Workflow load, compute both visible `GitHubWorkflowActivity` and all-run `GitHubWorkflowEvidence`. For each successful Review load, cache normalized direct requests and map to Activity items.

After the first phase, guard the connection generation, then build Check candidates from current/cached direct Reviews and Workflow evidence. Load at most four Check refs total / two per repository, respecting `.checks` capability.

- [ ] **Step 11: Implement source result aggregation and Core ordering**

Each source returns its own `GitHubActivitySurfaceResult`. Build `GitHubActivityLoadResult.items` from source caches and sort once with:

```swift
ActivityInboxOrdering().areInIncreasingOrder
```

Do not preserve the old provider-local state-only sort as the global order.

- [ ] **Step 12: Update existing provider test constructors and run all provider tests**

Every existing test that creates `GitHubActivityProvider(workflowRunLoader:)` must supply deterministic Review and Check loader stubs returning empty success arrays. Do not add production no-op loaders simply to preserve old test call sites.

Run:

```bash
tuist test SchneeBarGitHubActivityProviderTests -- -skipMacroValidation CODE_SIGNING_ALLOWED=NO
```

Expected: PASS, including old Workflow behavior and new multi-source tests.

- [ ] **Step 13: Commit**

```bash
git add Sources/SchneeBarGitHubActivityProvider Tests/SchneeBarGitHubActivityProviderTests
git commit -m "feat: aggregate GitHub activity sources"
```

---

### Task 7: Wire services into runtime and separate connection health from activity capability

**Files:**
- Modify: `Sources/SchneeBarApp/SchneeBarApp.swift`
- Modify: `Sources/SchneeBarApp/GitHubConnectionsRuntimeModel.swift`
- Modify: `Sources/SchneeBarGitHubFeature/GitHubConnectionManagementView.swift`
- Create: `Tests/SchneeBarAppTests/GitHubConnectionsRuntimeModelActivityTests.swift`
- Modify existing App/provider fixtures that construct `GitHubActivityProvider`.

**Interfaces:**
- `AppDelegate` creates one `GitHubReviewRequestService` and one `GitHubCheckRunService` using the same `GitHubConnectionSessionCoordinator` as Workflow services.
- `GitHubRepositoryOptionModel` replaces a single `actionsAccess` property with:

```swift
public struct GitHubRepositoryActivityAccessModel: Equatable, Sendable {
    public let actions: GitHubRepositoryActivityAccessPresentation
    public let reviewRequests: GitHubRepositoryActivityAccessPresentation
    public let checks: GitHubRepositoryActivityAccessPresentation
}
```

- [ ] **Step 1: Write RED runtime aggregate-ordering test**

Use a provider fixture returning three source items deliberately out of order: running Workflow, failed Check, action-required Review. Call `loadActivityItems()` and assert IDs are ordered Review -> Check -> Workflow using Core ordering.

- [ ] **Step 2: Write RED capability-only health test**

Create a healthy profile/inventory where all monitored repositories have `.actions`, `.pullRequests`, and `.checks` set to `.unavailable(.missingPermission)`. Make all source loaders fail the test if invoked. After `loadActivityItems()`, assert connection presentation status remains `.connected(repositoryCount: N)` and no source network call occurred.

- [ ] **Step 3: Write RED attempted-failure status tests**

Case A: Workflow succeeds while Review network fails -> connection remains connected and Workflow items remain. Case B: every attempted source fails with network-unavailable and no source succeeds -> connection becomes `.networkUnavailable`. Case C: any attempted source returns authentication-required -> provider resets and runtime status becomes `.authenticationRequired`.

- [ ] **Step 4: Implement runtime source-result policy**

Replace repository-count-only `applyActivityStatus` assumptions. Capability-blocked targets do not count as attempted operational failure. If any source target succeeds, restore normal `presentationStatus(for: inventory)`. If there are zero attempts because all sources are blocked, leave/restore normal connected status. Only derive network/unavailable status from attempted non-auth failures when no attempted target succeeds.

- [ ] **Step 5: Wire production services**

In `AppDelegate.init()`:

```swift
let reviewRequestService = GitHubReviewRequestService(sessionCoordinator: sessionCoordinator)
let checkRunService = GitHubCheckRunService(sessionCoordinator: sessionCoordinator)
let activityProvider = GitHubActivityProvider(
    workflowRunLoader: workflowRunService,
    reviewRequestLoader: reviewRequestService,
    checkRunLoader: checkRunService
)
```

Update App test fixtures with deterministic empty Review/Check loaders unless the test targets those sources.

- [ ] **Step 6: Write RED three-surface management-model tests**

For repository capability combinations `.available`, `.unknown`, `.unavailable`, assert `managementModel(profileID:)` maps each capability independently to `available`, `unverified`, or `unavailable`.

- [ ] **Step 7: Update `GitHubConnectionManagementView` presentation model**

Replace `actionsAccess` with `activityAccess`. Available states stay visually quiet. For unavailable/unverified states, render compact named badges such as `Actions unavailable`, `Reviews unverified`, `Checks unavailable`. Summary counts operate over monitored repositories and name the affected surface.

Do not add per-source toggles; monitoring remains repository-scoped.

- [ ] **Step 8: Run App and GitHub feature build/tests**

Run:

```bash
tuist test SchneeBarAppTests -- -skipMacroValidation CODE_SIGNING_ALLOWED=NO
tuist build -- -skipMacroValidation CODE_SIGNING_ALLOWED=NO
```

Expected: PASS.

- [ ] **Step 9: Commit**

```bash
git add Sources/SchneeBarApp/SchneeBarApp.swift Sources/SchneeBarApp/GitHubConnectionsRuntimeModel.swift Sources/SchneeBarGitHubFeature/GitHubConnectionManagementView.swift Tests/SchneeBarAppTests
git commit -m "feat: wire GitHub activity inbox"
```

---

### Task 8: Make Activity interaction kind-aware and add deterministic mixed Inbox visuals

**Files:**
- Modify: `Sources/SchneeBarActivityFeature/ActivityPopoverView.swift`
- Modify or create: `Tests/SchneeBarActivityFeatureTests/ActivityPopoverBehaviorTests.swift`
- Modify: `Sources/SchneeBarPreviewSupport/ActivityFixtures.swift`
- Modify: `Sources/SchneeBarPreviewSupport/GitHubConnectionFixtures.swift`
- Modify: `Sources/SchneeBarVisualHarness/SchneeBarVisualHarnessApp.swift`
- Modify: `Sources/SchneeBarVisualSnapshotCLI/main.swift`

**Interfaces:**
- `.workflowRun` can invoke the existing local detail loader/chevron.
- `.reviewRequest` and `.checkRun` are browser-link-only in this phase.
- No non-workflow row exposes help/accessibility text saying `Inspect workflow jobs`.

- [ ] **Step 1: Extract/test the local-detail affordance rule**

If direct SwiftUI hierarchy assertions are brittle, add an internal pure helper in the Activity feature:

```swift
func supportsLocalDetail(_ item: ActivityItem) -> Bool {
    item.kind == .workflowRun
}
```

Test:

```swift
@Test
func onlyWorkflowRunsSupportLocalDetail() {
    #expect(supportsLocalDetail(activity(kind: .workflowRun)))
    #expect(!supportsLocalDetail(activity(kind: .reviewRequest)))
    #expect(!supportsLocalDetail(activity(kind: .checkRun)))
}
```

- [ ] **Step 2: Update `ActivityPopoverView` behavior/copy**

Only render the chevron when `onInspect != nil && item.kind == .workflowRun`. Keep browser `Link` navigation for all items with `destinationURL`. Make icon/accessibility/help text generic per kind; workflow rows may still say `Inspect workflow jobs`, while Review/Check rows rely on browser-opening hints only.

- [ ] **Step 3: Add deterministic mixed Inbox fixture**

Create fictional values only:

```swift
public static let mixedInbox: [ActivityItem] = [
    ActivityItem(id: "review-1", repository: "snow-labs/frost", context: "PR #142", detail: "Review requested · Harden wake recovery", state: .waiting, destinationURL: URL(string: "https://github.com/snow-labs/frost/pull/142"), kind: .reviewRequest, attention: .actionRequired, updatedAt: fixtureDate(300)),
    ActivityItem(id: "check-1", repository: "snow-labs/frost", context: "Codecov", detail: "Failed · patch coverage", state: .failed, destinationURL: URL(string: "https://github.com/snow-labs/frost/commit/aaaaaaaa/checks"), kind: .checkRun, attention: .needsAttention, updatedAt: fixtureDate(200)),
    ActivityItem(id: "workflow-1", repository: "snow-labs/crystal", context: "main · CI", detail: "Running · Build", state: .running, destinationURL: URL(string: "https://github.com/snow-labs/crystal/actions/runs/123"), kind: .workflowRun, attention: .active, updatedAt: fixtureDate(100)),
]
```

Use the repo's existing deterministic date helper or add a fixed UTC/date constructor; do not use `Date.now`.

- [ ] **Step 4: Add capability visual fixture**

Create one connected management model where Actions is available, Reviews is unverified, and Checks is unavailable. The connection itself must remain visually connected; only source badges communicate capability limitations.

- [ ] **Step 5: Register visual scenes/snapshots**

Add at least:

```text
github-activity-mixed-inbox-light
github-activity-mixed-inbox-dark
github-activity-review-only-light
github-capability-mixed-surfaces-light
github-capability-mixed-surfaces-dark
```

Use the existing Visual Harness / Snapshot CLI naming and sizing conventions. Do not overwrite unrelated baseline scenarios.

- [ ] **Step 6: Run feature tests and local snapshot generation path**

Run:

```bash
tuist test SchneeBarActivityFeatureTests -- -skipMacroValidation CODE_SIGNING_ALLOWED=NO
tuist build SchneeBarVisualSnapshotCLI -- -skipMacroValidation CODE_SIGNING_ALLOWED=NO
```

Then run the same snapshot-render command used by `.github/workflows/visual.yml` for candidate output and inspect the generated report/images for clipping, badge crowding, and wrong chevrons.

Expected: mixed Inbox shows Review first, failed Check second, Workflow third; Review/Check rows have no local-detail chevron.

- [ ] **Step 7: Commit**

```bash
git add Sources/SchneeBarActivityFeature Sources/SchneeBarPreviewSupport Sources/SchneeBarVisualHarness Sources/SchneeBarVisualSnapshotCLI Tests/SchneeBarActivityFeatureTests
git commit -m "feat: present prioritized developer activity"
```

---

### Task 9: Update Phase 3 docs and verify the exact final head

**Files:**
- Modify: `docs/DEVELOPMENT_PLAN.md`
- Review all files changed by Tasks 1-8.

**Interfaces:**
- No new production API. This task closes the feature only after evidence from tests/build/Visual/CodeQL.

- [ ] **Step 1: Update `docs/DEVELOPMENT_PLAN.md` only after implementation is green locally**

Move these Phase 3 items into Implemented:

```text
- direct GitHub review-request activity
- Check Run activity for bounded activity-derived SHAs
- provider-neutral priority Inbox semantics
- three-surface Actions / Reviews / Checks capability presentation
- source-level activity failure/accounting with capability-only connection-health separation
```

Leave matrix-job aggregation and superseded-run handling in `Next` unless separately implemented by another change.

- [ ] **Step 2: Run the full local verification command set**

```bash
tuist generate
tuist build -- -skipMacroValidation CODE_SIGNING_ALLOWED=NO
tuist test -- -skipMacroValidation CODE_SIGNING_ALLOWED=NO
```

Expected: all commands exit 0.

- [ ] **Step 3: Perform security/invariant review before opening the PR**

Verify from the diff:

```text
- no token/credential values in UI/models/logs/fixtures
- Review matching uses stable account ID
- team membership is never inferred
- remote PR html_url / Check details_url is not trusted for navigation
- capability unavailable performs zero source call
- max per-refresh source calls remain 8 + 4 + 4
- successful hidden Workflow evidence contributes Check candidates
- only visible same-SHA Workflow evidence suppresses github-actions Check rows
- repository selection/reset clears all source caches/evidence
- capability-only blocks keep healthy connection connected
```

- [ ] **Step 4: Commit documentation**

```bash
git add docs/DEVELOPMENT_PLAN.md
git commit -m "docs: update developer activity progress"
```

- [ ] **Step 5: Open a draft PR and verify CI + Visual on the exact head**

PR summary must explicitly call out Review stable-ID matching, Check candidate request bounds, hidden-success Workflow evidence, source-result accounting, and connection-health separation.

Keep the PR draft while CI and Visual Regression run. Confirm both runs reference the exact current feature-head SHA and both conclude `success`.

- [ ] **Step 6: Mark Ready and run draft-gated CodeQL on the same head**

Do not push another commit after CI/Visual green unless all three gates are rerun. Mark Ready only after CI + Visual succeed on the exact head; then wait for CodeQL on that same SHA.

Expected final gate:

```text
CI                success
Visual Regression success
CodeQL            success
```

- [ ] **Step 7: Final review and merge**

Before merge, confirm:

```text
PR mergeable == true
PR draft == false
head SHA == SHA verified by CI/Visual/CodeQL
no unresolved review threads
```

Squash merge with an expected-head SHA guard. After merge, verify `main` points to the merge commit and its tree contains the verified feature contents.

# GitHub Review Requests + Checks Activity Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Turn Developer Activity into a bounded priority inbox that combines GitHub Actions, direct Pull Request review requests, and relevant Check Runs while preserving connection isolation, capability gating, and low idle overhead.

**Architecture:** `SchneeBarCore` owns provider-neutral activity kind, attention, ordering, and summary semantics. `SchneeBarGitHub` owns authenticated REST clients/services and normalized GitHub models. `SchneeBarGitHubActivityProvider` owns source scheduling, Workflow evidence, source caches, Check candidate planning, capability preflight, and source-level result accounting. The App runtime keeps connection health separate from capability-only blocks; SwiftUI receives only provider-neutral activity and normalized capability presentation.

**Tech Stack:** Swift 6.3, Swift Testing, Swift Concurrency/actors, SwiftUI, Observation, Tuist 4.203.1, Xcode 26.6, macOS 15+, GitHub REST API, GitHub Actions CI/Visual Regression/CodeQL.

**Spec:** `docs/superpowers/specs/2026-09-16-github-review-checks-activity-design.md`

## Global Constraints

- macOS deployment target remains 15.0.
- Xcode 26.6 / Swift 6.3 remain the production baseline; Xcode 27 / Swift 6.4 remain canary-only.
- Tuist stays pinned to 4.203.1 via mise.
- Domain/Application code remains independent of SwiftUI and AppKit.
- Raw GitHub REST payloads are normalized before crossing the `SchneeBarGitHub` adapter boundary.
- The session coordinator remains the only credential/session authority; tokens never enter App/UI state, fixtures, logs, or docs.
- Direct review identity matching uses the connected account's stable GitHub account ID, never login text alone.
- Team review requests are out of scope; repository access must not be used to infer team membership.
- Review polling is one page of at most 100 most-recently-updated open Pull Requests per selected repository poll.
- Check polling is one page of at most 100 Check Runs per candidate ref.
- Per connection / periodic refresh, activity source list requests are capped at 8 Workflow + 4 Review + 4 Check = 16. Session-layer credential refresh traffic is outside this source-list budget.
- Check discovery uses direct-review head SHAs plus recently polled Workflow Run head SHAs, including successful Workflow Runs hidden from the top-level inbox.
- GitHub Actions-owned Check Runs are suppressed only when an equivalent same-repository/same-SHA **visible** Workflow row exists.
- Capability `.unavailable` blocks that source without a network request; `.available` and `.unknown` remain requestable.
- Capability-only blocks never downgrade an otherwise healthy GitHub connection to connection-level `.unavailable`.
- A 401/authentication failure from any attempted source enters the existing `.authenticationRequired` recovery path.
- Repository monitoring selection gates Workflow, Review, and Check sources consistently.
- Provider reset/disable/selection changes invalidate stale async work across all sources.
- Do not add per-source preferences, team membership discovery, deployments, write actions, SQLite persistence, or a generic plugin framework in this change.

## File Structure

### Core and Activity feature

- `Sources/SchneeBarCore/ActivityItem.swift` — `ActivityKind`, `ActivityAttention`, `updatedAt`, backward-compatible Codable.
- `Sources/SchneeBarCore/ActivityInboxOrdering.swift` — one provider-neutral global comparator.
- `Sources/SchneeBarCore/ActivitySummary.swift` — attention-aware counts and fixed activity-neutral labels.
- `Sources/SchneeBarActivityFeature/ActivityWidgetProvider.swift` — map new summary semantics into Widget severity/priority/compact text.
- `Tests/SchneeBarCoreTests/ActivityItemTests.swift` — legacy decoding/defaults.
- `Tests/SchneeBarCoreTests/ActivityInboxOrderingTests.swift` — deterministic ordering.
- `Tests/SchneeBarCoreTests/ActivitySummaryTests.swift` — exact summary copy.
- `Tests/SchneeBarActivityFeatureTests/ActivityWidgetProviderTests.swift` — Review/Check-aware Widget behavior.

### GitHub adapter

- `Sources/SchneeBarGitHub/GitHubPullRequestListClient.swift` — one-page open-PR loader and normalized `GitHubReviewRequest`.
- `Sources/SchneeBarGitHub/GitHubReviewRequestService.swift` — session-authorized Review loader.
- `Sources/SchneeBarGitHub/GitHubCheckRunClient.swift` — one-page Check Run loader with Check-specific enums.
- `Sources/SchneeBarGitHub/GitHubCheckRunService.swift` — session-authorized Check loader.
- `Tests/SchneeBarGitHubTests/GitHubPullRequestListClientTests.swift`
- `Tests/SchneeBarGitHubTests/GitHubReviewRequestServiceTests.swift`
- `Tests/SchneeBarGitHubTests/GitHubCheckRunClientTests.swift`
- `Tests/SchneeBarGitHubTests/GitHubCheckRunServiceTests.swift`

### GitHub Activity provider

- `Sources/SchneeBarGitHubActivityProvider/GitHubReviewRequestActivityMapper.swift` — direct-review filtering and Activity mapping.
- `Sources/SchneeBarGitHubActivityProvider/GitHubWorkflowEvidence.swift` — provider-internal SHA evidence from **all** polled Workflow Runs.
- `Sources/SchneeBarGitHubActivityProvider/GitHubCheckCandidatePlanner.swift` — review-first / workflow-second SHA selection.
- `Sources/SchneeBarGitHubActivityProvider/GitHubCheckRunActivityMapper.swift` — Check mapping and same-SHA duplicate suppression.
- `Sources/SchneeBarGitHubActivityProvider/GitHubActivitySurfaceResult.swift` — formal source/target accounting contract.
- `Sources/SchneeBarGitHubActivityProvider/GitHubActivityProvider.swift` — bounded multi-source scheduling/caching/generation/capability integration.
- `Tests/SchneeBarGitHubActivityProviderTests/GitHubReviewRequestActivityMapperTests.swift`
- `Tests/SchneeBarGitHubActivityProviderTests/GitHubCheckCandidatePlannerTests.swift`
- `Tests/SchneeBarGitHubActivityProviderTests/GitHubCheckRunActivityMapperTests.swift`
- `Tests/SchneeBarGitHubActivityProviderTests/GitHubActivityProviderMultiSourceTests.swift`

### Runtime / presentation

- `Sources/SchneeBarApp/SchneeBarApp.swift` — compose Review/Check services.
- `Sources/SchneeBarApp/GitHubConnectionsRuntimeModel.swift` — consume source results; separate connection health from capability blocks; use Core ordering.
- `Sources/SchneeBarGitHubFeature/GitHubConnectionManagementView.swift` — three-surface capability presentation.
- `Sources/SchneeBarActivityFeature/ActivityPopoverView.swift` — kind-aware local detail/browser interaction.
- `Tests/SchneeBarAppTests/GitHubConnectionsRuntimeModelActivityTests.swift`
- `Tests/SchneeBarActivityFeatureTests/ActivityPopoverBehaviorTests.swift`

### Deterministic UI / docs

- `Sources/SchneeBarPreviewSupport/ActivityFixtures.swift`
- `Sources/SchneeBarPreviewSupport/GitHubConnectionFixtures.swift`
- `Sources/SchneeBarVisualHarness/SchneeBarVisualHarnessApp.swift`
- `Sources/SchneeBarVisualSnapshotCLI/main.swift`
- `docs/DEVELOPMENT_PLAN.md`

## Execution Prerequisite

Merge the approved design/plan documentation branch into `main`, then create `feat/github-review-checks-activity` from that exact `main`. Production code must not be implemented on the documentation branch.

```bash
# 1. Merge docs/github-review-checks-activity-design into main.
# 2. Create feat/github-review-checks-activity from the resulting main SHA.
# 3. Execute Tasks 1-9 in order.
```

---

### Task 1: Add provider-neutral Inbox semantics and make the Activity Widget attention-aware

**Files:**
- Modify: `Sources/SchneeBarCore/ActivityItem.swift`
- Create: `Sources/SchneeBarCore/ActivityInboxOrdering.swift`
- Modify: `Sources/SchneeBarCore/ActivitySummary.swift`
- Modify: `Sources/SchneeBarActivityFeature/ActivityWidgetProvider.swift`
- Create or modify: `Tests/SchneeBarCoreTests/ActivityItemTests.swift`
- Create: `Tests/SchneeBarCoreTests/ActivityInboxOrderingTests.swift`
- Modify: `Tests/SchneeBarCoreTests/ActivitySummaryTests.swift`
- Modify: `Tests/SchneeBarActivityFeatureTests/ActivityWidgetProviderTests.swift`

**Interfaces:**

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

`ActivityItem` adds:

```swift
public let kind: ActivityKind
public let attention: ActivityAttention
public let updatedAt: Date?
```

and its initializer becomes:

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

- [ ] **Step 1: Write RED backward-compatibility tests**

```swift
@Test
func decodesLegacyActivityItemWithWorkflowDefaults() throws {
    let json = #"{"id":"legacy-1","repository":"snow/app","context":"main · CI","detail":"Running","state":"running","destinationURL":null}"#
    let item = try JSONDecoder().decode(ActivityItem.self, from: Data(json.utf8))
    #expect(item.kind == .workflowRun)
    #expect(item.attention == .active)
    #expect(item.updatedAt == nil)
}
```

Add initializer-default assertions for failed/running/waiting/success.

- [ ] **Step 2: Run Core tests and verify RED**

```bash
tuist test SchneeBarCoreTests -- -skipMacroValidation CODE_SIGNING_ALLOWED=NO
```

Expected: compile failure because the new types/properties do not exist.

- [ ] **Step 3: Implement explicit Codable compatibility**

Do not use synthesized decoding for new required fields. Add `CodingKeys`, explicit `init(from:)`, and `encode(to:)`. Use:

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

Assert exact order `actionRequired -> needsAttention -> active/running -> active/waiting -> informational`. Within equal attention/state, sort newer dated items first, dated before undated, then repository, `kind.rawValue`, ID.

```swift
let sorted = items.sorted(by: ActivityInboxOrdering().areInIncreasingOrder)
#expect(sorted.map(\.id) == ["review", "failed-check", "running", "waiting", "success"])
```

- [ ] **Step 5: Implement `ActivityInboxOrdering` with explicit ranks**

```swift
private func attentionRank(_ value: ActivityAttention) -> Int {
    switch value {
    case .actionRequired: 0
    case .needsAttention: 1
    case .active: 2
    case .informational: 3
    }
}

private func stateRank(_ value: ActivityState) -> Int {
    switch value {
    case .failed: 0
    case .running: 1
    case .waiting: 2
    case .success: 3
    }
}
```

- [ ] **Step 6: Write RED exact-summary tests and implement fixed copy**

`ActivitySummary.menuBarLabel` is fixed to:

```text
actionRequired > 0  -> "Action N"
needsAttention > 0  -> "Alert N"
running > 0         -> "Running N"
waiting > 0         -> "Waiting N"
otherwise           -> "Clear"
```

Add `actionRequired` and `needsAttention` counts. Existing `failed/running/waiting/successful` counts remain available.

- [ ] **Step 7: Update the Activity Widget semantics with RED tests first**

Add tests:

```swift
@Test
func reviewRequestPromotesWidgetToAttention() async throws {
    let provider = ActivityWidgetProvider { [reviewActivity()] }
    let snapshot = try await provider.snapshot()
    #expect(snapshot.severity == .attention)
    #expect(snapshot.priority == .attention)
    #expect(snapshot.content(for: .normal).text == "Action 1")
    #expect(snapshot.content(for: .compact).text == "!1")
}

@Test
func failedCheckStillMakesWidgetCriticalWhenReviewAlsoExists() async throws {
    let provider = ActivityWidgetProvider { [reviewActivity(), failedCheckActivity()] }
    let snapshot = try await provider.snapshot()
    #expect(snapshot.severity == .critical)
    #expect(snapshot.priority == .critical)
    #expect(snapshot.content(for: .normal).text == "Action 1")
}
```

Implement Widget severity/priority:

```text
needsAttention/failed present -> critical / critical
actionRequired present        -> attention / attention
running present               -> active / attention
waiting present               -> attention / normal
otherwise                     -> nominal / normal
```

Compact copy is fixed to `!N`, `✕N`, `●N`, `◷N`, `✓` in that priority order. Update old `CI ✕1` assertions to the new activity-neutral labels.

- [ ] **Step 8: Run Core + ActivityFeature tests and commit**

```bash
tuist test SchneeBarCoreTests -- -skipMacroValidation CODE_SIGNING_ALLOWED=NO
tuist test SchneeBarActivityFeatureTests -- -skipMacroValidation CODE_SIGNING_ALLOWED=NO
git add Sources/SchneeBarCore Sources/SchneeBarActivityFeature/ActivityWidgetProvider.swift Tests/SchneeBarCoreTests Tests/SchneeBarActivityFeatureTests/ActivityWidgetProviderTests.swift
git commit -m "feat: add activity inbox semantics"
```

---

### Task 2: Add the bounded open-PR client and authenticated Review service

**Files:**
- Create: `Sources/SchneeBarGitHub/GitHubPullRequestListClient.swift`
- Create: `Sources/SchneeBarGitHub/GitHubReviewRequestService.swift`
- Create: `Tests/SchneeBarGitHubTests/GitHubPullRequestListClientTests.swift`
- Create: `Tests/SchneeBarGitHubTests/GitHubReviewRequestServiceTests.swift`

**Interfaces:**

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

- [ ] **Step 1: Write RED client request/normalization tests**

Use a recording transport. Assert path `/repos/{owner}/{repo}/pulls` and query:

```text
state=open
sort=updated
direction=desc
per_page=100
```

Assert reviewer numeric IDs become strings and `head.sha`, title, draft, timestamp normalize correctly.

- [ ] **Step 2: Write RED trust/error tests**

A malicious payload `html_url` must be ignored; returned `webURL` must equal the trusted connection endpoint path `/{owner}/{repo}/pull/{number}`. Cover blank credential, invalid repository identity, malformed required payload, and HTTP 401/403/404.

- [ ] **Step 3: Run GitHub tests and verify RED**

```bash
tuist test SchneeBarGitHubTests -- -skipMacroValidation CODE_SIGNING_ALLOWED=NO
```

- [ ] **Step 4: Implement `GitHubPullRequestListClient`**

Follow `GitHubPullRequestMetadataClient` headers/API-version conventions. Make exactly one list request; do not follow pagination links.

- [ ] **Step 5: Write RED service authorization test**

Seed a credential in a coordinator fixture, call `GitHubReviewRequestService.reviewRequests`, and assert the recording client transport receives an authorized request through `sessionCoordinator.authorizedCredential(connection:identity:clientID:)`.

- [ ] **Step 6: Implement the service**

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

- [ ] **Step 7: Run tests and commit**

```bash
tuist test SchneeBarGitHubTests -- -skipMacroValidation CODE_SIGNING_ALLOWED=NO
git add Sources/SchneeBarGitHub/GitHubPullRequestListClient.swift Sources/SchneeBarGitHub/GitHubReviewRequestService.swift Tests/SchneeBarGitHubTests/GitHubPullRequestListClientTests.swift Tests/SchneeBarGitHubTests/GitHubReviewRequestServiceTests.swift
git commit -m "feat: load GitHub review requests"
```

---

### Task 3: Filter direct Review Requests by stable account ID and map them to Activity

**Files:**
- Create: `Sources/SchneeBarGitHubActivityProvider/GitHubReviewRequestActivityMapper.swift`
- Create: `Tests/SchneeBarGitHubActivityProviderTests/GitHubReviewRequestActivityMapperTests.swift`

**Interfaces:**

```swift
public struct GitHubReviewRequestActivityMapper: Sendable {
    public init() {}

    public func visibleRequests(
        requests: [GitHubReviewRequest],
        identity: GitHubAccountIdentity
    ) -> [GitHubReviewRequest]

    public func activityItem(
        request: GitHubReviewRequest,
        repository: GitHubRepositoryAccess
    ) -> ActivityItem
}
```

- [ ] **Step 1: Write RED stable-ID tests**

Given identity `id = "42", login = "renamed-user"`, only PRs whose `requestedReviewerIDs` contain `"42"` are emitted. An empty reviewer set represents team-only/no-direct-user evidence and is not emitted. A changed login must not affect ID matching.

- [ ] **Step 2: Write RED Activity mapping test**

Assert:

```swift
#expect(item.id == "github-review:\(repository.id):\(request.number)")
#expect(item.kind == .reviewRequest)
#expect(item.attention == .actionRequired)
#expect(item.state == .waiting)
#expect(item.context == "PR #\(request.number)")
#expect(item.detail == "Review requested · \(request.title)")
#expect(item.updatedAt == request.updatedAt)
#expect(item.destinationURL == request.webURL)
```

- [ ] **Step 3: Implement mapper and deterministic sorting**

Sort visible direct requests by `updatedAt desc`, then PR number ascending for exact ties.

- [ ] **Step 4: Run tests and commit**

```bash
tuist test SchneeBarGitHubActivityProviderTests -- -skipMacroValidation CODE_SIGNING_ALLOWED=NO
git add Sources/SchneeBarGitHubActivityProvider/GitHubReviewRequestActivityMapper.swift Tests/SchneeBarGitHubActivityProviderTests/GitHubReviewRequestActivityMapperTests.swift
git commit -m "feat: map GitHub review activity"
```

---

### Task 4: Add the bounded Check Run client and authenticated Check service

**Files:**
- Create: `Sources/SchneeBarGitHub/GitHubCheckRunClient.swift`
- Create: `Sources/SchneeBarGitHub/GitHubCheckRunService.swift`
- Create: `Tests/SchneeBarGitHubTests/GitHubCheckRunClientTests.swift`
- Create: `Tests/SchneeBarGitHubTests/GitHubCheckRunServiceTests.swift`

**Interfaces:**

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

- [ ] **Step 1: Write RED enum-normalization tests**

Cover all known status/conclusion values plus unknown preservation. Explicitly assert:

```swift
#expect(try await loadSingleCheck(conclusion: "startup_failure").conclusion == .unknown("startup_failure"))
```

because `startup_failure` is a Workflow Run conclusion, not a known Check Run conclusion.

- [ ] **Step 2: Write RED request-bound/trust tests**

Assert path `/repos/{owner}/{repo}/commits/{sha}/check-runs`, `per_page=100`, exactly one HTTP request, and that arbitrary payload `details_url` is ignored. Returned `webURL` is reconstructed under the trusted repository endpoint for `commit/{sha}/checks`.

- [ ] **Step 3: Add RED validation/error tests**

Cover blank credential, invalid repository identity, blank SHA, malformed response, HTTP 401/403/404.

- [ ] **Step 4: Implement client**

Use existing Accept/API-version policy. Decode one page only. Parse optional timestamps and `app.slug`; do not expose third-party navigation URLs.

- [ ] **Step 5: Write RED service authorization test and implement service**

`GitHubCheckRunService` mirrors `GitHubWorkflowRunService`: obtain `authorizedCredential`, then call the client with repository + SHA.

- [ ] **Step 6: Run tests and commit**

```bash
tuist test SchneeBarGitHubTests -- -skipMacroValidation CODE_SIGNING_ALLOWED=NO
git add Sources/SchneeBarGitHub/GitHubCheckRunClient.swift Sources/SchneeBarGitHub/GitHubCheckRunService.swift Tests/SchneeBarGitHubTests/GitHubCheckRunClientTests.swift Tests/SchneeBarGitHubTests/GitHubCheckRunServiceTests.swift
git commit -m "feat: load GitHub check runs"
```

---

### Task 5: Add Workflow evidence, deterministic Check candidates, and Check Activity mapping

**Files:**
- Create: `Sources/SchneeBarGitHubActivityProvider/GitHubWorkflowEvidence.swift`
- Create: `Sources/SchneeBarGitHubActivityProvider/GitHubCheckCandidatePlanner.swift`
- Create: `Sources/SchneeBarGitHubActivityProvider/GitHubCheckRunActivityMapper.swift`
- Create: `Tests/SchneeBarGitHubActivityProviderTests/GitHubCheckCandidatePlannerTests.swift`
- Create: `Tests/SchneeBarGitHubActivityProviderTests/GitHubCheckRunActivityMapperTests.swift`

**Interfaces:**

Provider-private evidence:

```swift
struct GitHubWorkflowEvidence: Equatable, Sendable {
    let repositoryID: Int64
    let headSHA: String
    let classification: GitHubWorkflowActivityClassification
    let updatedAt: Date
    let isVisible: Bool
}
```

Candidate planner:

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

Public mapper does **not** expose the provider-private evidence type:

```swift
public struct GitHubCheckRunActivityMapper: Sendable {
    public init() {}

    public func visibleActivities(
        checks: [GitHubCheckRun],
        repository: GitHubRepositoryAccess,
        visibleWorkflowSHAs: Set<String>
    ) -> [ActivityItem]
}
```

- [ ] **Step 1: Write RED candidate tests**

Assert direct Review SHAs come first, successful hidden Workflow evidence still contributes a SHA, shared Review/Workflow SHAs deduplicate, max two refs per repository, max four total, deterministic repository order.

```swift
#expect(candidates.map(\.headSHA) == ["review-sha", "success-sha"])
```

- [ ] **Step 2: Implement candidate planner**

Within a repository: Reviews sort by `updatedAt desc`; Workflow evidence sorts classification `failed, running, waiting, success, ignored`, then `updatedAt desc`. Deduplicate preserving first occurrence. Enforce per-repository limit before global limit.

- [ ] **Step 3: Write RED Check mapping tests**

Assert failure/action-required/timed-out -> `.failed + .needsAttention`; queued/waiting/requested/pending -> `.waiting + .active`; in-progress -> `.running + .active`; success/neutral/skipped/cancelled/stale are omitted from top-level activity.

- [ ] **Step 4: Write RED same-SHA duplicate/fallback tests**

For `appSlug == "github-actions"`:

```text
SHA in visibleWorkflowSHAs     -> suppress Check row
SHA not in visibleWorkflowSHAs -> keep Check row
```

External checks such as `codecov` remain eligible even when the same SHA is visible as a Workflow row.

- [ ] **Step 5: Implement Check mapper**

Use ID `github-check:{repositoryID}:{checkID}`, `kind = .checkRun`, trusted `webURL`, and `updatedAt = completedAt ?? startedAt`. Duplicate suppression uses only `visibleWorkflowSHAs`, never hidden Workflow evidence.

- [ ] **Step 6: Run tests and commit**

```bash
tuist test SchneeBarGitHubActivityProviderTests -- -skipMacroValidation CODE_SIGNING_ALLOWED=NO
git add Sources/SchneeBarGitHubActivityProvider/GitHubWorkflowEvidence.swift Sources/SchneeBarGitHubActivityProvider/GitHubCheckCandidatePlanner.swift Sources/SchneeBarGitHubActivityProvider/GitHubCheckRunActivityMapper.swift Tests/SchneeBarGitHubActivityProviderTests/GitHubCheckCandidatePlannerTests.swift Tests/SchneeBarGitHubActivityProviderTests/GitHubCheckRunActivityMapperTests.swift
git commit -m "feat: add GitHub check activity planning"
```

---

### Task 6: Formalize source results and integrate bounded multi-source scheduling

**Files:**
- Create: `Sources/SchneeBarGitHubActivityProvider/GitHubActivitySurfaceResult.swift`
- Modify: `Sources/SchneeBarGitHubActivityProvider/GitHubActivityProvider.swift`
- Create: `Tests/SchneeBarGitHubActivityProviderTests/GitHubActivityProviderMultiSourceTests.swift`
- Modify existing provider tests that construct `GitHubActivityProvider`.

**Interfaces:**

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

public struct GitHubActivityLoadResult: Equatable, Sendable {
    public let items: [ActivityItem]
    public let surfaces: [GitHubActivitySurface: GitHubActivitySurfaceResult]
}
```

Add helpers `surface(_:)`, aggregate attempted/successful/blocked counts, and deterministic `failures` sorted by surface rank (`workflows`, `reviewRequests`, `checks`), repository ID, repository name, reason rank.

Provider initializer becomes:

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

- [ ] **Step 1: Add RED source-result identity tests**

Create Workflow success, Review forbidden, and Checks capability-blocked results for the same repository. Assert each surface retains separate counts/failures and aggregate helpers are deterministic.

- [ ] **Step 2: Add recording Review/Check loader stubs**

Use actor stubs that record `(connectionID, repositoryID)` for Reviews and `(connectionID, repositoryID, headSHA)` for Checks and return configured `Result` values.

- [ ] **Step 3: Write RED capability-gate tests**

`.pullRequests == .unavailable(.missingPermission)` -> zero Review calls + Review blocked count. `.checks == .unavailable` -> zero Check calls. `.unknown(...)` -> request remains allowed.

- [ ] **Step 4: Write RED hard-budget/fairness tests**

With enough eligible targets:

```swift
#expect(await workflowLoader.callCount() <= 8)
#expect(await reviewLoader.callCount() <= 4)
#expect(await checkLoader.callCount() <= 4)
#expect(await workflowLoader.callCount() + reviewLoader.callCount() + checkLoader.callCount() <= 16)
```

Across refreshes, at least one cold Review repository advances despite hot Review repositories.

- [ ] **Step 5: Write RED hidden-success external-Check regression**

Workflow at SHA `abc` succeeds and is hidden; external Check at `abc` fails. Returned top-level items must contain the Check and not the successful Workflow.

- [ ] **Step 6: Write RED duplicate/fallback tests**

Visible Workflow at `abc` + `github-actions` Check at `abc` -> only Workflow row. Hidden successful Workflow evidence at `abc` + failed `github-actions` Check -> Check row remains. External Check always remains eligible.

- [ ] **Step 7: Write RED partial-failure/cache replacement tests**

Review failure must not erase Workflow/Check items. A later successful empty Review response clears that Review cache. A later successful empty Check response clears that SHA's Check cache. Repository deselection removes all source caches and Workflow evidence for that repository.

- [ ] **Step 8: Write RED auth/stale-generation tests**

401 from any attempted source creates authentication-required failure on that surface. During an in-flight refresh, `reset(connectionID:)` then release the loader; stale completion must not repopulate any cache/evidence.

- [ ] **Step 9: Implement provider state**

Use separate maps:

```swift
private var cachedWorkflowActivities: [RepositoryPollKey: [GitHubWorkflowActivity]] = [:]
private var workflowEvidence: [RepositoryPollKey: [GitHubWorkflowEvidence]] = [:]
private var cachedReviewRequests: [RepositoryPollKey: [GitHubReviewRequest]] = [:]
private var cachedCheckActivities: [CheckPollKey: [ActivityItem]] = [:]
private var reviewPollState: [RepositoryPollKey: RepositoryPollState] = [:]
```

`CheckPollKey` contains connection ID, repository ID, head SHA. `reset`/pruning clear all maps consistently.

- [ ] **Step 10: Implement Workflow + Review phase**

For every successful Workflow target, create visible Workflow Activity plus Workflow evidence for **all fetched runs** using the mapper's public classification method. Set `isVisible` by matching visible activity run IDs/SHA evidence. For every successful Review target, filter stable-ID direct requests through `reviewMapper`, cache only those direct requests, and map them to Activity.

- [ ] **Step 11: Implement demand-driven Check phase**

After generation validation, build candidates from direct Review cache + Workflow evidence. Load at most four refs total/two per repository. Build `visibleWorkflowSHAs` from evidence where `isVisible == true`, then pass that `Set<String>` to `checkMapper.visibleActivities`.

- [ ] **Step 12: Aggregate source results and Core-sort once**

Build one `GitHubActivitySurfaceResult` per surface. Combine cached items and sort globally only with:

```swift
ActivityInboxOrdering().areInIncreasingOrder
```

Remove the old provider-global state-only ordering path.

- [ ] **Step 13: Update existing provider tests and run**

Existing tests that construct `GitHubActivityProvider(workflowRunLoader:)` must now inject deterministic empty-success Review/Check stubs. Do not add production no-op loaders to preserve old test syntax.

```bash
tuist test SchneeBarGitHubActivityProviderTests -- -skipMacroValidation CODE_SIGNING_ALLOWED=NO
```

- [ ] **Step 14: Commit**

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
- Modify App tests/fixtures that construct `GitHubActivityProvider`.

**Interfaces:**

```swift
public struct GitHubRepositoryActivityAccessModel: Equatable, Sendable {
    public let actions: GitHubRepositoryActivityAccessPresentation
    public let reviewRequests: GitHubRepositoryActivityAccessPresentation
    public let checks: GitHubRepositoryActivityAccessPresentation
}
```

`GitHubRepositoryOptionModel` replaces its single `actionsAccess` property with `activityAccess`.

- [ ] **Step 1: Write RED aggregate-ordering test**

Provider fixture returns running Workflow, failed Check, action-required Review in scrambled order. `loadActivityItems()` must return Review -> Check -> Workflow.

- [ ] **Step 2: Write RED capability-only health test**

Healthy session/inventory; all three capabilities unavailable. Source stubs fail if called. `loadActivityItems()` makes zero source calls and leaves status `.connected(repositoryCount: N)`.

- [ ] **Step 3: Write RED operational-failure status tests**

Workflow succeeds + Review network fails -> connected and Workflow item remains. All attempted sources network-fail with no success -> `.networkUnavailable`. Any auth failure -> `.authenticationRequired` and provider reset.

- [ ] **Step 4: Implement runtime policy**

Blocked targets are not attempted operational failures. Any successful attempted target restores normal `presentationStatus(for: inventory)`. Zero attempts because all surfaces are capability-blocked also leaves/restores normal connection status. Derive network/unavailable only from attempted non-auth failures when no attempted target succeeds.

- [ ] **Step 5: Wire production services**

```swift
let reviewRequestService = GitHubReviewRequestService(sessionCoordinator: sessionCoordinator)
let checkRunService = GitHubCheckRunService(sessionCoordinator: sessionCoordinator)
let activityProvider = GitHubActivityProvider(
    workflowRunLoader: workflowRunService,
    reviewRequestLoader: reviewRequestService,
    checkRunLoader: checkRunService
)
```

- [ ] **Step 6: Write RED three-surface management mapping tests**

For each repository, map `.available -> available`, `.unknown -> unverified`, `.unavailable -> unavailable` independently for Actions/Reviews/Checks.

- [ ] **Step 7: Update capability UI**

Available surfaces stay quiet. Unverified/unavailable surfaces render compact named badges: `Actions`, `Reviews`, `Checks`. Monitoring remains repository-scoped; no source toggles.

- [ ] **Step 8: Run tests/build and commit**

```bash
tuist test SchneeBarAppTests -- -skipMacroValidation CODE_SIGNING_ALLOWED=NO
tuist build -- -skipMacroValidation CODE_SIGNING_ALLOWED=NO
git add Sources/SchneeBarApp Sources/SchneeBarGitHubFeature/GitHubConnectionManagementView.swift Tests/SchneeBarAppTests
git commit -m "feat: wire GitHub activity inbox"
```

---

### Task 8: Make the popover kind-aware and add deterministic Visual Regression scenes

**Files:**
- Modify: `Sources/SchneeBarActivityFeature/ActivityPopoverView.swift`
- Create: `Tests/SchneeBarActivityFeatureTests/ActivityPopoverBehaviorTests.swift`
- Modify: `Sources/SchneeBarPreviewSupport/ActivityFixtures.swift`
- Modify: `Sources/SchneeBarPreviewSupport/GitHubConnectionFixtures.swift`
- Modify: `Sources/SchneeBarVisualHarness/SchneeBarVisualHarnessApp.swift`
- Modify: `Sources/SchneeBarVisualSnapshotCLI/main.swift`

**Interfaces:**

- `.workflowRun` may show the existing local job-detail chevron.
- `.reviewRequest` and `.checkRun` are browser-link-only.

Use an internal pure helper:

```swift
func supportsLocalDetail(kind: ActivityKind) -> Bool {
    kind == .workflowRun
}
```

- [ ] **Step 1: Write RED behavior test**

```swift
@Test
func onlyWorkflowRunsSupportLocalDetail() {
    #expect(supportsLocalDetail(kind: .workflowRun))
    #expect(!supportsLocalDetail(kind: .reviewRequest))
    #expect(!supportsLocalDetail(kind: .checkRun))
}
```

- [ ] **Step 2: Update `ActivityPopoverView`**

Render the inspect chevron only when `onInspect != nil && supportsLocalDetail(kind: item.kind)`. Keep browser `Link` behavior for any item with `destinationURL`. Non-workflow rows must not expose `Inspect workflow jobs` help/accessibility copy.

- [ ] **Step 3: Add deterministic mixed Inbox fixture**

Use fictional fixed data only:

```swift
public static let mixedInbox: [ActivityItem] = [
    ActivityItem(id: "review-1", repository: "snow-labs/frost", context: "PR #142", detail: "Review requested · Harden wake recovery", state: .waiting, destinationURL: URL(string: "https://github.com/snow-labs/frost/pull/142"), kind: .reviewRequest, attention: .actionRequired, updatedAt: fixtureDate(300)),
    ActivityItem(id: "check-1", repository: "snow-labs/frost", context: "Codecov", detail: "Failed · patch coverage", state: .failed, destinationURL: URL(string: "https://github.com/snow-labs/frost/commit/aaaaaaaa/checks"), kind: .checkRun, attention: .needsAttention, updatedAt: fixtureDate(200)),
    ActivityItem(id: "workflow-1", repository: "snow-labs/crystal", context: "main · CI", detail: "Running · Build", state: .running, destinationURL: URL(string: "https://github.com/snow-labs/crystal/actions/runs/123"), kind: .workflowRun, attention: .active, updatedAt: fixtureDate(100)),
]
```

Use an existing deterministic date helper or a fixed epoch helper; never `Date.now`.

- [ ] **Step 4: Add mixed capability fixture**

Connection remains connected while one repository presents Actions available, Reviews unverified, Checks unavailable.

- [ ] **Step 5: Register snapshots**

Add:

```text
github-activity-mixed-inbox-light
github-activity-mixed-inbox-dark
github-activity-review-only-light
github-capability-mixed-surfaces-light
github-capability-mixed-surfaces-dark
```

- [ ] **Step 6: Run feature tests and snapshot build path**

```bash
tuist test SchneeBarActivityFeatureTests -- -skipMacroValidation CODE_SIGNING_ALLOWED=NO
tuist build SchneeBarVisualSnapshotCLI -- -skipMacroValidation CODE_SIGNING_ALLOWED=NO
```

Then run the same candidate-render command used by `.github/workflows/visual.yml`; inspect for clipping, badge crowding, wrong chevrons, and ordering.

- [ ] **Step 7: Commit**

```bash
git add Sources/SchneeBarActivityFeature/ActivityPopoverView.swift Sources/SchneeBarPreviewSupport Sources/SchneeBarVisualHarness Sources/SchneeBarVisualSnapshotCLI Tests/SchneeBarActivityFeatureTests/ActivityPopoverBehaviorTests.swift
git commit -m "feat: present prioritized developer activity"
```

---

### Task 9: Update Phase 3 documentation and verify the exact final head

**Files:**
- Modify: `docs/DEVELOPMENT_PLAN.md`
- Review all Task 1-8 changes.

- [ ] **Step 1: Update `docs/DEVELOPMENT_PLAN.md` after local green**

Move into Phase 3 Implemented:

```text
- direct GitHub review-request activity
- bounded Check Run activity for activity-derived SHAs
- provider-neutral priority Inbox semantics
- Actions / Reviews / Checks capability presentation
- source-level activity failure/accounting with capability-only connection-health separation
```

Leave matrix-job aggregation and superseded-run handling in `Next`.

- [ ] **Step 2: Run full local verification**

```bash
tuist generate
tuist build -- -skipMacroValidation CODE_SIGNING_ALLOWED=NO
tuist test -- -skipMacroValidation CODE_SIGNING_ALLOWED=NO
```

Expected: all exit 0.

- [ ] **Step 3: Perform final invariant review**

Verify from the diff:

```text
no credentials in UI/models/logs/fixtures
Review matching uses stable account ID
team membership is never inferred
remote PR html_url / Check details_url is not trusted
capability unavailable performs zero source call
source-list budget remains 8 + 4 + 4
successful hidden Workflow evidence contributes Check candidates
only visible same-SHA Workflow suppresses github-actions Check rows
repository selection/reset clears every source cache/evidence
capability-only blocks keep a healthy connection connected
non-workflow rows never show local Workflow-job inspect UI
```

- [ ] **Step 4: Commit docs**

```bash
git add docs/DEVELOPMENT_PLAN.md
git commit -m "docs: update developer activity progress"
```

- [ ] **Step 5: Open a draft PR and verify exact-head CI + Visual**

PR body explicitly documents stable-ID Review matching, request bounds, hidden-success Workflow evidence, source-result accounting, and connection-health separation. Keep draft until CI and Visual Regression both succeed on the exact current head SHA.

- [ ] **Step 6: Mark Ready and verify draft-gated CodeQL on the same head**

Do not push after CI/Visual green unless every gate reruns. Final exact-head gate is:

```text
CI                success
Visual Regression success
CodeQL            success
```

- [ ] **Step 7: Final review and squash merge**

Confirm:

```text
PR mergeable == true
PR draft == false
head SHA == SHA verified by CI/Visual/CodeQL
no unresolved review threads
```

Squash merge with expected-head SHA guard, then verify `main` points to the merge commit and contains the verified tree.

# GitHub Capability Contract Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a session-scoped, repository-aware GitHub capability assessment and use it to avoid definitively unsupported Actions polling without creating false negatives for public repositories or untested GitHub Enterprise Server versions.

**Architecture:** `SchneeBarGitHub` owns pure evidence evaluation from `GitHubConnection + GitHubAccessInventory`. `GitHubConnectionSession` exposes only normalized capability assessment, the App runtime caches that assessment beside access inventory, and `SchneeBarGitHubActivityProvider` preflight-blocks only `.unavailable` Actions repositories while `.unknown` remains requestable. No capability-specific REST probes or persisted capability state are added.

**Tech Stack:** Swift 6.3, Swift Testing, Swift Concurrency, Tuist 4.203.1, Xcode 26.6, macOS 15+, GitHub Actions CI/Visual Regression/CodeQL.

**Spec:** `docs/superpowers/specs/2026-09-15-github-capability-contract-design.md`

## Global Constraints

- macOS deployment target remains 15.0.
- Xcode 26.6 / Swift 6.3 remain the production baseline; Xcode 27 / Swift 6.4 remain canary-only.
- Tuist stays pinned to 4.203.1 via mise.
- Domain/Application code must not depend on SwiftUI or AppKit.
- Provider DTOs must be normalized before generic UI state.
- GitHub capability interpretation stays inside `SchneeBarGitHub`; App/UI code must not interpret raw installation permission keys.
- Do not add capability-probe REST calls; evaluation uses the already-loaded connection and access inventory.
- Capability state is session-scoped and must not be persisted into `GitHubConnectionProfile`.
- `.unknown` remains requestable. Only `.unavailable` may preflight-block a repository request.
- Missing fine-grained permission on a public repository is `.unknown`, not `.unavailable`.
- Untested or unknown GHES version is uncertainty, never a hard unsupported result by itself.
- Bearer tokens, refresh tokens, private GHES URLs, raw server error payloads, and real private repository data must never be committed.
- Preserve the existing hot/cold Activity polling budget and stale-generation behavior.

## Execution Prerequisite

Before implementation, merge the approved design/plan PR into `main`, then create `feat/github-capability-contract` from that exact `main`. Do not implement production code on the design branch.

Recommended branch sequence:

```bash
# Conceptual sequence; perform with the repository's normal GitHub workflow.
# 1. Merge the design/plan PR after CI / Visual / CodeQL are green.
# 2. Create feat/github-capability-contract from the resulting main SHA.
# 3. Execute Tasks 1-5 in order.
```

---

### Task 1: Add the pure capability assessment model and evaluator

**Files:**
- Create: `Sources/SchneeBarGitHub/GitHubCapabilityAssessment.swift`
- Modify: `Sources/SchneeBarGitHub/GitHubConnection.swift`
- Create: `Tests/SchneeBarGitHubTests/GitHubCapabilityAssessmentTests.swift`

**Interfaces:**
- Consumes: `GitHubCapability`, `GitHubConnection`, `GitHubAccessInventory`, `GitHubInstallationAccess`, `GitHubRepositoryAccess`, `GitHubEnterpriseCompatibilityPolicy`.
- Produces:

```swift
public enum GitHubCapabilityBlocker: Equatable, Sendable {
    case missingPermission
}

public enum GitHubCapabilityUncertainty: Hashable, Sendable {
    case publicRepositoryPermissionNotProven
    case untestedEnterpriseVersion
    case unknownEnterpriseVersion
    case unmappedCapability
    case unrecognizedPermissionLevel
    case conflictingEvidence
}

public enum GitHubCapabilityState: Equatable, Sendable {
    case available
    case unavailable(GitHubCapabilityBlocker)
    case unknown(Set<GitHubCapabilityUncertainty>)
}

public struct GitHubRepositoryCapabilityAssessment: Equatable, Sendable {
    public let repositoryID: Int64
    public let states: [GitHubCapability: GitHubCapabilityState]

    public init(
        repositoryID: Int64,
        states: [GitHubCapability: GitHubCapabilityState]
    )
}

public enum GitHubInstallationCapabilityIssueReason: Equatable, Sendable {
    case suspended
    case forbidden
    case notFound
    case unavailable
}

public struct GitHubInstallationCapabilityIssue: Equatable, Sendable {
    public let installationID: Int64
    public let reason: GitHubInstallationCapabilityIssueReason

    public init(
        installationID: Int64,
        reason: GitHubInstallationCapabilityIssueReason
    )
}

public struct GitHubConnectionCapabilityAssessment: Equatable, Sendable {
    public let repositories: [Int64: GitHubRepositoryCapabilityAssessment]
    public let installationIssues: [GitHubInstallationCapabilityIssue]

    public init(
        repositories: [Int64: GitHubRepositoryCapabilityAssessment] = [:],
        installationIssues: [GitHubInstallationCapabilityIssue] = []
    )

    public func state(
        for capability: GitHubCapability,
        repositoryID: Int64
    ) -> GitHubCapabilityState?
}

public struct GitHubCapabilityEvaluator: Sendable {
    public init(
        compatibilityPolicy: GitHubEnterpriseCompatibilityPolicy = .init()
    )

    public func evaluate(
        connection: GitHubConnection,
        inventory: GitHubAccessInventory
    ) -> GitHubConnectionCapabilityAssessment
}
```

- Remove `GitHubCapabilitySet` from `GitHubConnection.swift`; no parallel boolean capability source remains.

- [ ] **Step 1: Write the failing evaluator tests**

Create `Tests/SchneeBarGitHubTests/GitHubCapabilityAssessmentTests.swift` with focused fixtures and tests covering the full evidence matrix. The first RED batch must include at least these cases:

```swift
import Foundation
import SchneeBarGitHub
import Testing

@Test
func hostedActionsReadPermissionIsAvailable() throws {
    let repository = try capabilityRepository(id: 1, isPrivate: true)
    let result = GitHubCapabilityEvaluator().evaluate(
        connection: try hostedCapabilityConnection(),
        inventory: capabilityInventory(
            repository: repository,
            permissions: ["actions": "read"]
        )
    )

    #expect(result.state(for: .actions, repositoryID: 1) == .available)
}

@Test
func hostedActionsWritePermissionAlsoSatisfiesReadCapability() throws {
    let repository = try capabilityRepository(id: 1, isPrivate: true)
    let result = GitHubCapabilityEvaluator().evaluate(
        connection: try hostedCapabilityConnection(),
        inventory: capabilityInventory(
            repository: repository,
            permissions: ["actions": "WRITE"]
        )
    )

    #expect(result.state(for: .actions, repositoryID: 1) == .available)
}

@Test
func privateRepositoryWithoutActionsPermissionIsUnavailable() throws {
    let repository = try capabilityRepository(id: 1, isPrivate: true)
    let result = GitHubCapabilityEvaluator().evaluate(
        connection: try hostedCapabilityConnection(),
        inventory: capabilityInventory(repository: repository, permissions: [:])
    )

    #expect(
        result.state(for: .actions, repositoryID: 1)
            == .unavailable(.missingPermission)
    )
}

@Test
func publicRepositoryWithoutActionsPermissionRemainsUnknown() throws {
    let repository = try capabilityRepository(id: 1, isPrivate: false)
    let result = GitHubCapabilityEvaluator().evaluate(
        connection: try hostedCapabilityConnection(),
        inventory: capabilityInventory(repository: repository, permissions: [:])
    )

    #expect(
        result.state(for: .actions, repositoryID: 1)
            == .unknown([.publicRepositoryPermissionNotProven])
    )
}

@Test
func untestedEnterpriseAndPublicPermissionFallbackPreserveBothUncertainties() throws {
    let repository = try capabilityRepository(id: 1, isPrivate: false)
    let connection = try enterpriseCapabilityConnection(serverVersion: "3.23.0")
    let result = GitHubCapabilityEvaluator().evaluate(
        connection: connection,
        inventory: capabilityInventory(repository: repository, permissions: [:])
    )

    #expect(
        result.state(for: .actions, repositoryID: 1)
            == .unknown([
                .untestedEnterpriseVersion,
                .publicRepositoryPermissionNotProven,
            ])
    )
}
```

Also add tests for:

```swift
#expect(result.state(for: .pullRequests, repositoryID: 1) == .available) // pull_requests=read
#expect(result.state(for: .checks, repositoryID: 1) == .available)       // checks=read
#expect(result.state(for: .deployments, repositoryID: 1) == .available)  // deployments=read
#expect(result.state(for: .releases, repositoryID: 1) == .unknown([.unmappedCapability]))
```

Add a duplicate-evidence test where repository ID 9 appears in two available installations, one with `actions=read` and one without it. Expect `.unknown` containing `.conflictingEvidence` rather than selecting either installation.

Add installation issue tests that map `.suspended`, `.forbidden`, `.notFound`, and `.unavailable` to normalized `GitHubInstallationCapabilityIssue` values and create no repository assessment for an installation that exposed no repositories.

Fixtures must use synthetic public hosts such as `https://github.example.test`; do not use private real-world infrastructure names.

- [ ] **Step 2: Run the suite and verify the intended RED failure**

Run:

```bash
mise exec -- tuist test -- -skipMacroValidation CODE_SIGNING_ALLOWED=NO
```

Expected: compilation/test failure because `GitHubCapabilityEvaluator`, `GitHubCapabilityState`, and related assessment types do not yet exist. Do not implement until this failure is observed on the feature branch/PR.

- [ ] **Step 3: Implement the assessment types and pure evaluator**

Create `Sources/SchneeBarGitHub/GitHubCapabilityAssessment.swift` with the public types above. Implement four v1 permission policies exactly:

```swift
private static let permissionKeys: [GitHubCapability: String] = [
    .actions: "actions",
    .pullRequests: "pull_requests",
    .checks: "checks",
    .deployments: "deployments",
]
```

For an available installation, normalize permission levels with:

```swift
let level = rawLevel?
    .trimmingCharacters(in: .whitespacesAndNewlines)
    .lowercased()
```

Rules for mapped capabilities:

```swift
switch level {
case "read", "write":
    // available if platform has no uncertainty; otherwise unknown(platform uncertainties)
case nil, "":
    // private repository => unavailable(.missingPermission)
    // public repository => unknown(platform uncertainties + publicRepositoryPermissionNotProven)
default:
    // unknown(platform uncertainties + unrecognizedPermissionLevel)
}
```

For unmapped capabilities return `.unknown([.unmappedCapability])` plus any platform uncertainty only if useful for diagnostics; never manufacture `.available` for an unmapped capability.

Platform uncertainty helper behavior:

```swift
switch connection.deploymentKind {
case .githubDotCom, .gheDotCom:
    []
case .enterpriseServer:
    switch compatibilityPolicy.compatibility(
        for: connection.serverVersion.flatMap(GitHubEnterpriseServerVersion.init(parsing:))
    ) {
    case .tested:
        []
    case .olderUntested, .newerUntested:
        [.untestedEnterpriseVersion]
    case .unknownVersion:
        [.unknownEnterpriseVersion]
    }
}
```

Merge duplicate repository assessments capability-by-capability. If two states differ, return `.unknown` containing `.conflictingEvidence` plus uncertainty sets already present in either state. Do not silently prefer `.available` or `.unavailable`.

Sort `installationIssues` by `installationID`, then reason in a stable explicit order so Equatable-based tests remain deterministic.

Remove `GitHubCapabilitySet` from `GitHubConnection.swift` in the same production commit.

- [ ] **Step 4: Run tests and verify GREEN**

Run:

```bash
mise exec -- tuist test -- -skipMacroValidation CODE_SIGNING_ALLOWED=NO
```

Expected: all existing tests plus the new `GitHubCapabilityAssessmentTests` pass.

- [ ] **Step 5: Commit the independently reviewable evaluator slice**

```bash
git add Sources/SchneeBarGitHub/GitHubCapabilityAssessment.swift \
  Sources/SchneeBarGitHub/GitHubConnection.swift \
  Tests/SchneeBarGitHubTests/GitHubCapabilityAssessmentTests.swift
git commit -m "feat: evaluate GitHub capabilities from access evidence"
```

### Task 2: Attach fresh capability assessment to connection sessions

**Files:**
- Modify: `Sources/SchneeBarGitHub/GitHubConnectionSessionCoordinator.swift`
- Modify: `Tests/SchneeBarGitHubTests/GitHubConnectionSessionCoordinatorTests.swift`

**Interfaces:**
- Consumes: `GitHubCapabilityEvaluator.evaluate(connection:inventory:)` from Task 1.
- Produces:

```swift
public struct GitHubConnectionSession: Equatable, Sendable {
    public let connectionID: UUID
    public let account: GitHubAuthenticatedAccount
    public let credentialKey: GitHubCredentialKey
    public let inventory: GitHubAccessInventory
    public let capabilities: GitHubConnectionCapabilityAssessment
}
```

`GitHubConnectionSessionCoordinator` gains an injected pure evaluator with default construction:

```swift
private let capabilityEvaluator: GitHubCapabilityEvaluator

public init(
    credentialStore: any GitHubCredentialStore,
    accessClient: GitHubAccessClient = GitHubAccessClient(),
    deviceFlowClient: GitHubDeviceFlowClient = GitHubDeviceFlowClient(),
    capabilityEvaluator: GitHubCapabilityEvaluator = .init(),
    now: @escaping @Sendable () -> Date = { .now },
    refreshLeeway: TimeInterval = 300
)
```

- [ ] **Step 1: Add failing session tests**

Extend `GitHubConnectionSessionCoordinatorTests.swift` with an `establish` test whose queued inventory contains one private repository under an installation with `"permissions":{"actions":"read"}`. After `establish`, assert:

```swift
#expect(
    session.capabilities.state(for: .actions, repositoryID: 1001)
        == .available
)
```

Add a `restore` regression that performs two restores against fresh inventory evidence: first `actions=read`, then missing Actions permission for the same private repository. The second returned session must be `.unavailable(.missingPermission)`, proving the result is recomputed rather than persisted/stale.

Use the existing `SessionQueueTransport`; provide complete synthetic `/user`, `/user/installations`, and installation-repositories payloads. Do not add a new production abstraction solely to simplify the test.

- [ ] **Step 2: Run tests and verify RED**

Run:

```bash
mise exec -- tuist test -- -skipMacroValidation CODE_SIGNING_ALLOWED=NO
```

Expected: compilation failure because `GitHubConnectionSession` has no `capabilities` property.

- [ ] **Step 3: Implement minimal session integration**

After each successful fresh inventory load in both `establish` and `restore`, compute:

```swift
let capabilities = capabilityEvaluator.evaluate(
    connection: connection,
    inventory: inventory
)
```

Pass that value into `GitHubConnectionSession`. Do not evaluate capabilities before inventory succeeds, and do not write capabilities into the profile or credential stores.

- [ ] **Step 4: Run tests and verify GREEN**

Run:

```bash
mise exec -- tuist test -- -skipMacroValidation CODE_SIGNING_ALLOWED=NO
```

Expected: all session and evaluator tests pass; existing refresh-token single-flight behavior remains unchanged.

- [ ] **Step 5: Commit the session slice**

```bash
git add Sources/SchneeBarGitHub/GitHubConnectionSessionCoordinator.swift \
  Tests/SchneeBarGitHubTests/GitHubConnectionSessionCoordinatorTests.swift
git commit -m "feat: attach capability assessment to GitHub sessions"
```

### Task 3: Cache normalized capability assessment in the App runtime

**Files:**
- Modify: `Sources/SchneeBarApp/GitHubConnectionsRuntimeModel.swift`

**Interfaces:**
- Consumes: `GitHubConnectionSession.capabilities` from Task 2.
- Produces an App-local cache only:

```swift
@ObservationIgnored
private var capabilitiesByConnectionID: [UUID: GitHubConnectionCapabilityAssessment] = [:]
```

No capability presentation UI is added.

- [ ] **Step 1: Add the cache to successful connection paths**

On onboarding success and refresh success, immediately store the normalized assessment next to inventory:

```swift
inventoryByConnectionID[profile.id] = session.inventory
capabilitiesByConnectionID[profile.id] = session.capabilities
```

- [ ] **Step 2: Clear capability state on every inventory-invalidating path**

Whenever disable, disconnect, or authentication invalidation removes `inventoryByConnectionID`, remove capability state in the same branch:

```swift
capabilitiesByConnectionID.removeValue(forKey: profileID)
```

A transient network error that does not clear last-known-good inventory must also keep last-known-good capability assessment. Do not fabricate a new assessment during a failed refresh.

- [ ] **Step 3: Build and test the thin App integration**

Run:

```bash
mise exec -- tuist build -- -skipMacroValidation CODE_SIGNING_ALLOWED=NO
mise exec -- tuist test -- -skipMacroValidation CODE_SIGNING_ALLOWED=NO
```

Expected: Build and Test pass. No UI-visible behavior changes yet because the cache is not consumed until Task 4.

- [ ] **Step 4: Commit the cache slice**

```bash
git add Sources/SchneeBarApp/GitHubConnectionsRuntimeModel.swift
git commit -m "feat: cache GitHub capability assessments in runtime"
```

### Task 4: Preflight Actions polling with definitive capability evidence

**Files:**
- Modify: `Sources/SchneeBarGitHubActivityProvider/GitHubActivityProvider.swift`
- Modify: `Tests/SchneeBarGitHubActivityProviderTests/GitHubActivityProviderTests.swift`
- Modify: `Sources/SchneeBarApp/GitHubConnectionsRuntimeModel.swift`

**Interfaces:**
- Consumes: `GitHubConnectionCapabilityAssessment` from Task 1 and App cache from Task 3.
- Changes Activity load API to:

```swift
public func load(
    profile: GitHubConnectionProfile,
    inventory: GitHubAccessInventory,
    capabilities: GitHubConnectionCapabilityAssessment? = nil
) async -> GitHubActivityLoadResult
```

- Extends failure/result types:

```swift
public enum GitHubRepositoryActivityFailureReason: Equatable, Sendable {
    case authenticationRequired
    case forbidden
    case notFound
    case networkUnavailable
    case unavailable
    case capabilityUnavailable
}

public struct GitHubActivityLoadResult: Equatable, Sendable {
    public let items: [ActivityItem]
    public let failures: [GitHubRepositoryActivityFailure]
    public let successfulRepositoryCount: Int
    public let attemptedRepositoryCount: Int
    public let blockedRepositoryCount: Int

    public var consideredRepositoryCount: Int {
        attemptedRepositoryCount + blockedRepositoryCount
    }
}
```

Keep `blockedRepositoryCount` defaulting to `0` in the public initializer so existing source call sites outside this slice remain source-compatible.

- [ ] **Step 1: Add failing preflight tests before production changes**

Add a private-repository test with an explicit Actions-unavailable assessment:

```swift
@Test
func actionsUnavailableSkipsWorkflowRequestAndCountsBlock() async throws {
    let repository = try repository(
        id: 1,
        fullName: "acme/private",
        isPrivate: true
    )
    let loader = ActivityLoaderStub(responses: [1: .success([])])
    let provider = GitHubActivityProvider(workflowRunLoader: loader)
    let profile = try githubProfile(selection: .allAccessible)
    let inventory = try githubInventory(repositories: [repository])
    let capabilities = GitHubConnectionCapabilityAssessment(
        repositories: [
            1: GitHubRepositoryCapabilityAssessment(
                repositoryID: 1,
                states: [.actions: .unavailable(.missingPermission)]
            ),
        ]
    )

    let result = await provider.load(
        profile: profile,
        inventory: inventory,
        capabilities: capabilities
    )

    #expect(await loader.requestedIDs().isEmpty)
    #expect(result.attemptedRepositoryCount == 0)
    #expect(result.blockedRepositoryCount == 1)
    #expect(result.consideredRepositoryCount == 1)
    #expect(
        result.failures == [
            GitHubRepositoryActivityFailure(
                repositoryID: 1,
                repositoryFullName: "acme/private",
                reason: .capabilityUnavailable
            ),
        ]
    )
}
```

Add an unknown-state test:

```swift
#expect(
    capabilities.state(for: .actions, repositoryID: 1)
        == .unknown([.publicRepositoryPermissionNotProven])
)
// provider.load(...) must still call the loader once.
```

Also verify `.available` and `capabilities: nil` retain existing request behavior.

Add a mixed test with one blocked private repository and multiple eligible repositories under `maximumRepositoriesPerRefresh`. Assert the request budget counts only actual network attempts, blocked repositories never consume the network budget, and hot/cold scheduling remains deterministic among eligible repositories.

Update the test `repository(...)` helper to accept `isPrivate: Bool = false` rather than duplicating fixture builders.

- [ ] **Step 2: Run tests and verify RED**

Run:

```bash
mise exec -- tuist test -- -skipMacroValidation CODE_SIGNING_ALLOWED=NO
```

Expected: compilation failure because the new load parameter/result fields/failure reason do not exist.

- [ ] **Step 3: Implement capability partitioning before scheduling**

Start from the existing monitored repositories. Partition them deterministically:

```swift
let blockedRepositories = repositories.filter {
    guard let state = capabilities?.state(for: .actions, repositoryID: $0.id) else {
        return false
    }
    if case .unavailable = state { return true }
    return false
}

let eligibleRepositories = repositories.filter { repository in
    !blockedRepositories.contains(where: { $0.id == repository.id })
}
```

Use an ID set in production instead of the O(n²) illustrative `contains` form:

```swift
let blockedRepositoryIDs = Set(blockedRepositories.map(\.id))
let eligibleRepositories = repositories.filter { !blockedRepositoryIDs.contains($0.id) }
```

Call `pruneState` with **all currently monitored repositories**, then remove cached activity/poll state for newly blocked repository IDs so previously cached CI does not remain visible after a permission downgrade.

Only pass `eligibleRepositories` to `repositoriesForRefresh`; `.unknown`, `.available`, and missing assessments stay eligible.

Create one `.capabilityUnavailable` failure for every blocked monitored repository on each load. Combine those failures with network/runtime failures and sort with the existing deterministic failure order.

`attemptedRepositoryCount` equals only `repositoriesToPoll.count`. `blockedRepositoryCount` equals `blockedRepositories.count`. `consideredRepositoryCount` remains a computed property.

- [ ] **Step 4: Wire normalized capability cache into the App runtime**

Change the call in `loadActivityItems()` to:

```swift
let result = await activityProvider.load(
    profile: profile,
    inventory: inventory,
    capabilities: capabilitiesByConnectionID[profile.id]
)
```

Aggregate considered work separately:

```swift
var consideredRepositoryCount = 0
...
consideredRepositoryCount += result.consideredRepositoryCount
```

Use `consideredRepositoryCount > 0` instead of `attemptedRepositoryCount > 0` when deciding whether all selected work failed.

Change `applyActivityStatus` to guard on considered work:

```swift
guard result.consideredRepositoryCount > 0 else { return }
```

Treat capability blocks as a non-transient unavailable state:

```swift
} else if result.failures.allSatisfy({
    $0.reason == .forbidden
        || $0.reason == .notFound
        || $0.reason == .capabilityUnavailable
}) {
    statusByConnectionID[profileID] = .unavailable
}
```

Do not include `.capabilityUnavailable` in the transient network-outage predicate.

- [ ] **Step 5: Run full tests and verify GREEN**

Run:

```bash
mise exec -- tuist test -- -skipMacroValidation CODE_SIGNING_ALLOWED=NO
```

Expected: all evaluator/session/Activity tests and the existing suite pass. Existing selected-repository, deduplication, concurrency, hot/cold polling, and stale-result tests must remain green.

- [ ] **Step 6: Commit the Activity integration slice**

```bash
git add Sources/SchneeBarGitHubActivityProvider/GitHubActivityProvider.swift \
  Tests/SchneeBarGitHubActivityProviderTests/GitHubActivityProviderTests.swift \
  Sources/SchneeBarApp/GitHubConnectionsRuntimeModel.swift
git commit -m "feat: gate GitHub activity with capability evidence"
```

### Task 5: Sync the development plan and run exact-head verification

**Files:**
- Modify: `docs/DEVELOPMENT_PLAN.md`
- Review only: `.github/workflows/ci.yml`
- Review only: `.github/workflows/visual.yml`
- Review only: `.github/workflows/codeql.yml`

**Interfaces:**
- Consumes: completed Tasks 1-4.
- Produces: documentation that accurately marks the Phase 2 capability contract foundation implemented without claiming capability UI, review requests, Checks, or deployments are implemented.

- [ ] **Step 1: Update Phase 2 documentation conservatively**

Move the capability-contract foundation from `Remaining` into `Implemented foundation` using wording equivalent to:

```markdown
- session-scoped, repository-aware capability assessment for Actions, Pull Requests, Checks, and Deployments
- conservative public-repository and untested-GHES capability evidence handling
```

Keep these as remaining work:

```markdown
- clearer unsupported-capability states in UI
- multi-account lifecycle and switching UX hardening
- connection recovery / credential-expiry UX
- broader enterprise connection validation before Phase 5
```

Do not mark Phase 2 complete solely because the capability contract foundation lands.

- [ ] **Step 2: Run fresh local-equivalent verification on the final implementation head**

Run in this exact order:

```bash
mise install
mise exec -- tuist generate
mise exec -- tuist build -- -skipMacroValidation CODE_SIGNING_ALLOWED=NO
mise exec -- tuist test -- -skipMacroValidation CODE_SIGNING_ALLOWED=NO
mise exec -- tuist run SchneeBarVisualSnapshotCLI -- --output .visual/capability-contract
```

Expected: generate, build, tests, and deterministic visual snapshot rendering all succeed on the same final head SHA.

- [ ] **Step 3: Commit documentation after successful local-equivalent verification**

```bash
git add docs/DEVELOPMENT_PLAN.md
git commit -m "docs: record GitHub capability contract foundation"
```

- [ ] **Step 4: Open/update a Draft implementation PR and verify PR workflows**

The implementation PR body must summarize:

```markdown
- evidence-based repository capability assessment
- public repository missing permissions remain unknown
- untested/unknown GHES remains requestable
- fresh session recomputation
- Actions preflight blocks only definitive unavailability
- attempted vs blocked Activity accounting
```

While Draft, require:

```text
CI / Build: success
CI / Test: success
Visual Regression: success
CodeQL: skipped by Draft gate
```

If CI/Test/Visual fails, use systematic debugging: inspect the first failing step/log, identify the root cause, add a regression test when applicable, make the minimum fix, and rerun the failed gate plus the full relevant suite.

- [ ] **Step 5: Mark Ready and require CodeQL on the exact implementation head**

After Draft CI and Visual are green, mark the PR Ready. Verify the Ready-triggered CodeQL run uses the same head SHA and completes:

```text
Generate Xcode project: success
Initialize CodeQL: success
Build for analysis: success
Analyze: success
```

Do not merge based on an older CodeQL run from a previous head.

- [ ] **Step 6: Perform final review gate before merge**

Before merging:

```text
- PR head SHA is unchanged from the verified head.
- CI Build/Test are green on that head.
- Visual Regression is green on that head.
- CodeQL is green on that head.
- No unresolved inline review threads remain.
- No requested-changes review remains active.
- Diff contains no token, secret, private GHES URL, or unrelated refactor.
- `GitHubCapabilitySet` is removed and no second boolean capability truth source exists.
- `.unknown` paths still reach normal Actions requests.
- only `.unavailable` paths are preflight-blocked.
```

Then squash merge with `expected_head_sha` protection and fetch `main` again to confirm the merge commit is the repository head.

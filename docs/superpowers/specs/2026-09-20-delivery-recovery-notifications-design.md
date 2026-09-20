# Delivery Recovery Notifications — Phase 4 Seventh Vertical Slice

Date: 2026-09-20
Status: Approved for implementation from the continue-development instruction
Stack base: `feat/delivery-evidence-explanations@e380d8e66db3d380e0e7d404de988e0383ab372a`

## 1. Purpose

Notify the user when a Pull Request-scoped GitHub Workflow lane that SchneeBar previously observed failing later returns to success.

"Recovery" in this slice means Delivery/CI recovery. It does not mean GitHub connection re-authentication.

The first slice is intentionally conservative:
- no extra GitHub requests;
- no persisted recovery history;
- no branch/push recovery inference without a single Pull Request identity;
- no deployment background polling;
- no notification action/deep link;
- no repository/account names in macOS notification content.

## 2. Existing Evidence

Developer Activity already polls up to the existing bounded Workflow run limit and receives successful Workflow runs even though successful runs are normally hidden from the Inbox. The provider already runs supersession resolution before mapping visible activities.

Therefore recovery detection can operate on the already-fetched, supersession-resolved Workflow runs with zero network expansion.

## 3. Recovery Lane Identity

Only runs with exactly one positive Pull Request number participate.

A lane is:

`workflowID + event + pullRequestNumber`

This deliberately matches the existing conservative PR-scoped supersession identity.

Not supported in this slice:
- push/default-branch lanes without a unique Pull Request identity;
- runs with zero Pull Request numbers;
- runs with multiple distinct positive Pull Request numbers;
- deployment-only recovery;
- Check Run recovery independent of Workflow recovery.

These remain deferred because lane identity would otherwise require new inference rules.

## 4. Recovery State Machine

State is in-memory and repository-scoped.

For each lane retain:
- latest observed run number;
- latest observed run ID;
- whether a failure is armed;
- armed failed run number/ID;
- last emitted successful run ID.

Cold start:
- first successful poll seeds state;
- it never emits a historical recovery from runs that completed before SchneeBar observed the lane.

Failure:
- a completed Workflow classification that maps to existing `.failed` arms recovery;
- a later failed run replaces the armed failure.

Waiting/running:
- do not emit;
- do not clear an armed failure.

Ignored completion:
- cancelled/skipped/neutral/stale do not emit;
- do not claim recovery;
- keep an existing armed failure so a later proven success can recover it.

Success:
- emit only if the lane was already armed by a previously observed failure;
- newer run number success emits;
- same run number/run ID transition from failed to success may emit to support GitHub re-run semantics that do not expose a modeled run-attempt field;
- after emission clear the armed failure and record emitted success ID;
- repeated polls of the same success emit nothing.

Stale/older observations:
- never roll state backward;
- never re-arm or re-emit.

## 5. Provider-Normalized Core Event

Add a provider-neutral Core model:

```swift
public struct DeliveryRecoveryEvent: Identifiable, Equatable, Sendable {
    public let id: String
    public let repository: String
    public let title: String
    public let detail: String
    public let destinationURL: URL?
    public let occurredAt: Date
}
```

GitHub provider event example:
- repository: `owner/repo`
- title: `CI recovered`
- detail: `PR #47 succeeded after a previously observed failed workflow run`
- destinationURL: trusted normalized Workflow web URL
- occurredAt: successful run update time

No SHA, actor identity, commit message, account email, API URL, or token enters the event.

## 6. GitHub Workflow Recovery Tracker

Add `GitHubWorkflowRecoveryTracker` in `SchneeBarGitHubActivityProvider`.

Input:
- supersession-resolved `[GitHubWorkflowRun]`
- `GitHubRepositoryAccess`

Output:
- zero or more `DeliveryRecoveryEvent`

Properties:
- deterministic;
- no I/O;
- uses existing `GitHubWorkflowActivityMapper.classification(for:)` or exactly equivalent existing classification semantics;
- emits events sorted by occurredAt descending then ID;
- never uses branch/time/name similarity as lane identity.

## 7. Provider Integration

`GitHubActivityProvider.loadWorkflowRepositories` already obtains:
1. Workflow runs;
2. supersession-resolved current runs;
3. visible Activity mapping;
4. hidden Workflow evidence.

Extend the internal successful Workflow outcome to retain the current runs.

After concurrent repository loading completes, the provider actor updates the repository tracker sequentially and aggregates recovery events.

Tracker lifecycle:
- retain state across ordinary successful polls;
- retain state across transient repository load failures;
- prune state when repository monitoring is removed;
- clear state on provider connection reset/disable/disconnect.

## 8. Load Result Replay Safety

Extend `GitHubActivityLoadResult`:

```swift
public let recoveryEvents: [DeliveryRecoveryEvent]
```

Initializers default to an empty array for source compatibility.

Recovery events are ephemeral edge events, not cached state.

Critical invariant:
- `lastResultByConnectionID` must cache the same items/surfaces with `recoveryEvents: []`;
- a concurrent/re-entrant `load` that returns the last cached result must never replay a previously emitted recovery.

## 9. App Runtime Delivery

Add an App-layer callback:

```swift
@ObservationIgnored
var onDeliveryRecovery:
    (@MainActor @Sendable (DeliveryRecoveryEvent) -> Void)?
```

Inside `loadActivityItems()`:
- only after the profile/result generation is still valid;
- invoke the callback once per returned recovery event;
- then continue existing item/status aggregation.

Recovery notification delivery failure must not fail Activity loading.

## 10. macOS Notification Adapter

Use Apple `UserNotifications` in the App target.

Add a small protocol so tests never depend on the real notification center.

```swift
protocol DeliveryRecoveryNotifying: Sendable {
    func prepareAuthorization() async
    func deliver(_ event: DeliveryRecoveryEvent) async
}
```

Production adapter:
- checks current `UNNotificationSettings`;
- on `.notDetermined`, requests provisional alert authorization;
- accepts `.authorized` and `.provisional`;
- on denied/unsupported state, silently no-ops;
- re-checks current settings before every delivery because users can change notification settings at any time;
- schedules an immediate local notification with `trigger: nil`;
- uses the Recovery event ID as the request identifier;
- no sound;
- no badge;
- no category/action;
- no URL/userInfo payload in this slice.

Apple documents that local notifications use `UNNotificationRequest`, a nil trigger requests immediate delivery, authorization status should be checked before scheduling, and provisional authorization delivers noninterrupting Notification Center notifications without an initial prompt.

## 11. Notification Privacy

The system notification intentionally does not include:
- repository full name;
- Pull Request number;
- branch;
- workflow name;
- GitHub account;
- GitHub host;
- destination URL.

First-slice content:

Title:
`Delivery recovered`

Body:
`A monitored workflow succeeded after a previously observed failure.`

This avoids leaking private repository context on the lock screen or Notification Center.

The normalized event keeps richer local context for future in-app surfaces, but the system adapter minimizes it.

## 12. App Wiring

`AppDelegate` owns the production notification adapter.

At launch:
- call `prepareAuthorization()` asynchronously;
- do not block app startup.

Configure:
- `githubRuntimeModel.onDeliveryRecovery` to hand events to the notifier in an unstructured Task;
- notification delivery failure is swallowed/loggable but never changes GitHub connection or Activity state.

No notification-center delegate is required in this slice because notifications have no actions and foreground presentation behavior is not customized.

## 13. Request and Cost Invariants

GitHub:
- zero additional HTTP requests;
- existing Workflow polling limits unchanged;
- existing complete explicit Delivery detail ceiling stays 12;
- standalone history stays 1 request.

macOS:
- one local notification scheduling operation per emitted recovery edge;
- no server/APNs requirement.

## 14. Failure Modes

Notification authorization denied:
- Activity behavior unchanged;
- no repeated permission prompt;
- no notification.

Notification scheduling error:
- Activity behavior unchanged;
- tracker state still marks recovery emitted to avoid notification storms.

Transient GitHub polling failure:
- retain armed failure state;
- emit only after a later successful poll proves success.

Provider reset/disable/disconnect:
- clear tracker state;
- re-enable/reconnect seeds cold state without historical notification.

Concurrent Activity loads:
- cached results carry no recovery events;
- no replay.

App relaunch:
- tracker state is intentionally lost;
- first poll seeds only;
- persisted recovery continuity is deferred with persisted Delivery history.

## 15. Tests

### Core
- DeliveryRecoveryEvent construction/equality.

### Tracker
- cold failed run arms but does not emit;
- cold successful run does not emit;
- observed failed → later success emits once;
- repeated success does not emit;
- newer failure re-arms;
- waiting/running preserve armed failure;
- cancelled/skipped/neutral/stale do not claim recovery;
- same run identity failed → success emits once;
- older runs do not roll state backward;
- zero/multiple PR identities never create a lane;
- distinct workflowID/event/PR lanes do not cross;
- emitted text contains no raw SHA.

### Provider
- recovery detection adds zero Workflow loader calls;
- state retained across a transient repository load failure;
- reset/prune clears state;
- cached/re-entrant load result never replays recovery event;
- recovery event ordering deterministic.

### App runtime
- valid recovery events invoke callback once;
- stale/disabled profile result does not notify;
- notification callback failure cannot fail Activity loading.

### Notification adapter
Using an injected fake notification-center port:
- notDetermined prepares provisional alert authorization;
- authorized/provisional schedule;
- denied does not schedule;
- settings are re-read before delivery;
- request identifier equals event ID;
- trigger is immediate;
- title/body are generic and contain no repository/PR/workflow/URL details;
- scheduling errors do not throw into Activity runtime.

### Regression
- existing Workflow/Review/Check polling request budgets unchanged;
- existing success-hidden Inbox behavior unchanged;
- existing supersession tests remain green;
- existing 12-request detail and 1-request history tests remain green.

## 16. Acceptance Criteria

- A failure observed by SchneeBar can arm a PR-scoped Workflow recovery lane.
- A later proven success on the same lane emits exactly one recovery event.
- No recovery is emitted from cold historical data.
- Recovery detection adds zero GitHub HTTP requests.
- Successful Workflow runs remain hidden from Developer Activity Inbox as before.
- System notification content leaks no repository/account/branch/PR/workflow identity.
- Denied notification permission does not affect Activity.
- Repeated polling cannot replay the same recovery event.
- No persisted state is introduced.
- CI, Visual Regression, and CodeQL pass on the exact implementation head.

## 17. Deferred Follow-up

- persisted recovery continuity across app relaunch;
- notification actions/deep links;
- opt-in detailed notification content;
- branch/push lane recovery when identity can be proven conservatively;
- Deployment recovery requiring a background Deployment observation design;
- Check Run-specific recovery notifications;
- persisted Delivery history.

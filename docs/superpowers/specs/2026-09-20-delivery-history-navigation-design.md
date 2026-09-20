# Standalone Delivery History / Navigation — Phase 4 Fifth Vertical Slice

Date: 2026-09-20  
Status: Approved for implementation from the continue-development instruction  
Base: \`main@53ae8d6c01e22adf9c9705cd2046432bbbb385d0\`

## 1. Purpose

Add a repository-scoped standalone Delivery history surface that can be opened from an already-loaded Workflow Activity detail.

The first slice is intentionally an index/navigation surface, not a bulk correlation engine. Opening history must be cheap. Full PR → merge → branch execution → deployment/environment correlation remains demand-driven in the existing Workflow detail path.

## 2. Product Goals

- Let a user move from a Workflow Activity detail into recent repository Workflow execution history without leaving SchneeBar.
- Keep the already-loaded Activity detail intact so Back from history is instantaneous and does not repeat the 12-request Delivery detail path.
- Load the initial history with exactly one GitHub Actions feature request.
- Preserve successful, failed, cancelled, skipped, neutral, and stale completed executions as history instead of applying Inbox filtering.
- Clearly distinguish a proven repository default branch from other branches using the existing exact, case-sensitive branch rule.
- Keep every history destination URL trusted and reconstructed by existing GitHub endpoint logic.
- Keep history explicit-demand-only. No background history polling and no persistence in this slice.

## 3. Non-Goals

- No persisted Delivery history.
- No background Delivery history refresh.
- No bulk PR correlation for the 20 visible history rows.
- No bulk Deployment or Environment lookup for history rows.
- No Release correlation.
- No workflow YAML fetch.
- No branch-list endpoint.
- No new GitHub permission.
- No write/re-run/cancel actions.
- No repository picker/global history entry point in this slice.
- No local drill-down from a history row back into a different Workflow detail in this slice; rows keep a trusted browser destination. Local row inspection can be added later without changing the history data contract.

## 4. Existing Architecture

Current popover flow:

Developer Activity Inbox
→ Workflow Activity Detail
→ Delivery section + Jobs

Current detail is held by ActivityRuntimeModel:
- selectedItem
- detail
- detailIsLoading
- detailErrorMessage

Current GitHub detail composition resolves the exact runtime repository from GitHubAccessInventory and then performs demand-driven Jobs + Delivery enrichment.

GitHubActionsClient already supports:
- repository workflow-run listing
- status filter
- branch/event filter
- per_page <= 100
- bounded pagination
- requested result limit

GitHub documents the repository workflow-runs endpoint as requiring Actions read permission and supporting status, branch, event, per_page, and page filters. The current SchneeBar connection model already has the required Actions capability.

## 5. User Flow

1. User opens Developer Activity.
2. User selects a Workflow row and opens local detail.
3. If local detail is loaded for an exact runtime repository, the header exposes a History action.
4. User selects History.
5. SchneeBar preserves the current detail snapshot and shows a repository-scoped Delivery History view.
6. History performs one explicit request for the 20 most recent completed Workflow runs.
7. User can open a history row in the browser.
8. User selects Back.
9. SchneeBar returns to the exact previously loaded Workflow detail without reloading Jobs or Delivery evidence.

Failure behavior:
- History failure never destroys the existing detail.
- Retry retries only the one history request.
- Back cancels in-flight history loading and returns to detail.
- If the underlying selected Activity disappears from refreshed Inbox state, the existing detail lifecycle remains authoritative and the history state is cleared with detail dismissal.

## 6. Data Contract

Add provider-neutral Core models.

\`DeliveryHistoryEntry\`:
- id: String
- title: String
- detail: String?
- state: ActivityDetailState
- destinationURL: URL?
- occurredAt: Date

\`DeliveryHistorySnapshot\`:
- repository: String
- entries: [DeliveryHistoryEntry]

No provider-specific run ID, SHA, branch object, or GitHub DTO enters Core.

Entry IDs are stable provider-produced identifiers such as the existing GitHub Actions repository/run composite. Core treats them as opaque strings.

## 7. GitHub Evidence Contract

Add a small provider mapper in SchneeBarGitHubActivityProvider:

\`GitHubDeliveryHistoryMapper\`

Input:
- repository: GitHubRepositoryAccess
- runs: [GitHubWorkflowRun]

Output:
- DeliveryHistorySnapshot

The mapper:
- sorts by updatedAt descending, then run ID descending;
- keeps only completed runs supplied by the loader;
- maps success to success;
- maps failure, timed_out, startup_failure, action_required to failed;
- maps cancelled, skipped, neutral, stale, unknown conclusion, or missing conclusion to neutral;
- never maps a completed row to waiting/running;
- never exposes raw SHA;
- never uses PR correlation to claim a delivery;
- never changes history membership based on Inbox visibility rules.

## 8. Branch Presentation

For each row:

If run.headBranch, after surrounding whitespace/newline trimming, exactly equals repository.defaultBranch:
- use \`Default branch\`

Otherwise if a non-empty headBranch exists:
- show that branch name as received after surrounding whitespace/newline trimming

Otherwise:
- use \`Branch unavailable\`

Comparison remains case-sensitive:
- \`main == main\` → Default branch
- \`Main != main\` → branch text \`Main\`

Default-branch metadata remains presentation-only.

## 9. History Row Presentation

Suggested row structure:

Title:
- Workflow name

Detail:
- status label · branch label · Run #N

Examples:
- Succeeded · Default branch · Run #812
- Failed · release/1.x · Run #811
- Cancelled · feature/test · Run #810

If displayTitle differs from workflow name, do not add it to the first slice. This keeps the 340-point popover readable and deterministic.

## 10. GitHub Loading Contract

Use the existing GitHubWorkflowRunService / GitHubActionsClient.

Query:
- status: completed
- limit: 20
- no branch filter
- no event filter

Why no branch filter:
- SchneeBar must preserve non-default release-branch history.
- default-branch metadata is presentation information, not history membership authority.
- filtering only the default branch would hide valid release execution history.

Request budget:
- one repository workflow-runs request on normal first-page results;
- \`per_page=20\`, \`page=1\`;
- no PR, commit-association, Deployment, Environment, Jobs, or repository-detail requests.

The underlying generic client can paginate when asked for larger limits, but this feature fixes its limit to 20 so the initial slice remains one request.

## 11. Runtime Composition

Add an App-layer method:

\`GitHubConnectionsRuntimeModel.loadDeliveryHistory(for:workflowRunLoader:historyMapper:)\`

Resolution rules mirror Activity detail:
- Activity must have a trusted Workflow run destination URL.
- Match enabled profile by canonical web host + port.
- Resolve exactly one repository from runtime inventory using exact fullName.
- Actions capability \`unavailable\` means history is unavailable without a feature request.
- Actions capability \`available\` or \`unknown\` remains explicitly requestable.
- No repository-detail fallback request.

The runtime method calls the existing workflow loader once with:
- \`GitHubWorkflowRunQuery(status: .completed, limit: 20)\`

and maps the result into Core history.

## 12. Activity Runtime Navigation State

Do not replace the current Activity detail navigation architecture with SwiftUI NavigationStack in this slice.

Extend ActivityRuntimeModel with independent history state:
- deliveryHistory: DeliveryHistorySnapshot?
- deliveryHistoryIsLoading: Bool
- deliveryHistoryErrorMessage: String?
- isPresentingDeliveryHistory: Bool
- deliveryHistoryLoader closure
- deliveryHistoryTask

Methods:
- configureDeliveryHistoryLoader
- requestDeliveryHistory
- retryDeliveryHistory
- dismissDeliveryHistory

Important invariant:
- selectedItem and detail remain untouched while history is shown.
- dismissDeliveryHistory returns to the same loaded detail without another detail request.

dismissDetail must:
- cancel detail task;
- cancel history task;
- clear history presentation and history state.

## 13. UI

### ActivityDetailView

Add optional \`onShowHistory\`.

Render a compact History button in the header only when:
- callback is non-nil;
- detail has loaded successfully.

The action is local navigation, not a browser link.

### DeliveryHistoryView

New provider-neutral SwiftUI view:
- 340-point width;
- repository header;
- Back button;
- loading state;
- retryable error state;
- empty state;
- scrollable list of at most 20 entries;
- existing ActivityDetailState icon/color language;
- trusted external link indicator only when destinationURL exists.

No provider name is required in the Core UI.

### PopoverRootView

Render order:
1. if isPresentingDeliveryHistory and selectedItem exists → DeliveryHistoryView
2. else if selectedItem exists → ActivityDetailView
3. else → ActivityPopoverView

This preserves the current custom navigation behavior and avoids a broad navigation-stack refactor.

## 14. Failure Modes

### Authentication expired
History load fails. Existing detail remains visible after Back. Runtime status continues to be owned by existing connection lifecycle; history must not independently mutate connection state.

### Actions capability unavailable
Return history-unavailable before feature network request.

### Network unavailable
Show retryable history error. Preserve detail.

### Empty repository history
Show a normal empty state, not an error.

### Duplicate run IDs
GitHubActionsClient already de-duplicates run IDs while paging. Mapper still sorts deterministically.

### Missing branch
Show Branch unavailable.

### Unknown conclusion
Show neutral history state and a conservative Completed/Unknown label; never classify as success.

## 15. Observability / Request Budget

No new telemetry backend is introduced.

Tests must prove:
- history open performs exactly one feature HTTP request for a 20-row page;
- \`per_page=20\`;
- \`page=1\`;
- \`status=completed\`;
- no \`/pulls/\`, \`/commits/\`, \`/deployments\`, \`/environments\`, \`/jobs\`, or repository-detail request is made;
- opening and backing out of history does not re-run Activity detail loading.

## 16. Security / Privacy

- Reuse authorized credential resolution.
- Keep Actions read as the only required history capability.
- Do not retain actor identity, commit message, head commit email, raw SHA, API URL, or repository response payload.
- Use GitHubActionsClient reconstructed trusted web URLs.
- Do not expose secrets or variables.
- No write endpoint.
- No pull_request_target workflow change.
- No background access expansion.

## 17. Performance / Cost

Feature request cost:
- normal history open: 1 REST request
- retry: +1 per explicit retry
- Back: 0
- background refresh: 0

The current GitHub authenticated-user primary REST limit is substantially larger than this feature's explicit request footprint; the design nevertheless keeps history to one request because SchneeBar already has separate Activity and detail budgets.

UI:
- max 20 rows
- lazy list rendering
- no image/avatar loading
- no per-row network request

## 18. Tests

### Core
- DeliveryHistoryEntry / Snapshot equality and construction.

### GitHub mapper
- success/failure/neutral conclusion mapping;
- exact default-branch label;
- case mismatch;
- non-default release branch;
- blank branch;
- deterministic updatedAt/id ordering;
- raw SHA absent from output.

### Runtime
- exact runtime inventory repository is used;
- defaultBranch reaches mapper;
- Actions unavailable performs zero feature requests;
- unknown remains requestable;
- ambiguous repository fullName is rejected;
- one completed-runs request with limit 20.

### ActivityRuntimeModel
- history preserves selectedItem/detail;
- Back restores exact existing detail without reloading;
- retry only repeats history loader;
- dismissDetail cancels and clears history;
- stale async completion cannot repopulate history after Back/dismiss.

### UI behavior
- History button visibility;
- Back callback;
- external link behavior;
- empty/loading/error states.

### Visual Regression
Light/Dark:
- default + non-default mixed history;
- neutral/cancelled history;
- empty history;
- request failure.

## 19. Acceptance Criteria

- User can open repository Delivery History from a loaded Workflow detail.
- User can return to the exact existing detail without a second detail load.
- History initial load is exactly one feature request.
- At most 20 rows are shown.
- Default-branch wording is evidence-backed and case-sensitive.
- Non-default branches remain visible.
- No row triggers bulk correlation.
- No background history polling.
- Existing 12-request Workflow detail ceiling is unchanged.
- CI, Visual Regression, and CodeQL pass on the exact implementation head.

## 20. Deferred Follow-up

- local history-row drill-down into another Workflow detail;
- global repository picker / history entry point;
- paginated Load More;
- persisted history;
- full delivery-history records independent of current GitHub retention;
- release correlation;
- richer evidence/confidence explanation.

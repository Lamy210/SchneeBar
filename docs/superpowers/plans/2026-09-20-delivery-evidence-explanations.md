# Delivery Confidence / Evidence Explanations Implementation Plan

Date: 2026-09-20

Goal: Preserve and render the evidence already used by Delivery correlation without changing correlation semantics or network budgets.

Spec: `docs/superpowers/specs/2026-09-20-delivery-evidence-explanations-design.md`

## Global Constraints

- Zero additional HTTP requests.
- No GitHub permission expansion.
- No correlation-gate relaxation.
- No raw SHA in Core/UI.
- Existing detailed Delivery ceiling remains 12 requests.
- Existing standalone history ceiling remains 1 request.
- Deployment/Environment enrichment remains best-effort.
- TDD for production changes.

## Task 1 — Core evidence contract

Files:
- Modify `Sources/SchneeBarCore/DeliveryTimeline.swift`
- Modify `Tests/SchneeBarCoreTests/DeliveryTimelineTests.swift`

RED:
- tests reference `DeliveryTimelineEvidenceState`, `DeliveryTimelineEvidenceItem`, and `DeliveryTimelineSnapshot.evidence`.

GREEN:
- add provider-neutral evidence state/item;
- add snapshot evidence with default empty array.

## Task 2 — Exact-correlation evidence checklist

Files:
- Modify `Sources/SchneeBarGitHubActivityProvider/GitHubDeliveryTimelineBuilder.swift`
- Modify `Tests/SchneeBarGitHubActivityProviderTests/GitHubDeliveryTimelineBuilderTests.swift`

RED:
- exact merged-PR correlation expects deterministic confirmed evidence;
- evidence text must not contain selected/base SHA.

GREEN:
- build confirmed checklist from already-proven gates.

## Task 3 — Missing-evidence explanations

Files:
- same builder/test files.

RED:
- ambiguous selected PR;
- missing/mismatched PR metadata;
- non-merged PR;
- blank target branch;
- no eligible target branch execution;
- missing commit association.

GREEN:
- return `.evidenceUnavailable/.unknown` with confirmed prerequisites plus first material missing item.

Do not alter event/correlation behavior.

## Task 4 — Deployment exact-match explanation

Files:
- builder/tests.

RED:
- appended Deployment events add one `Deployment commit match` confirmed item;
- repeated append does not duplicate the item.

GREEN:
- append one sanitized count-based explanation only when deployment events are actually appended.

## Task 5 — Technical failure explanation

Files:
- Modify `Sources/SchneeBarApp/GitHubConnectionsRuntimeModel+ActivityDetail.swift`
- Modify `Tests/SchneeBarAppTests/GitHubConnectionsRuntimeModelActivityDetailTests.swift`

RED:
- non-cancellation Delivery evidence load failure expects one `.unavailable` item.

GREEN:
- create sanitized provider-neutral technical failure evidence.

## Task 6 — UI disclosure

Files:
- Modify `Sources/SchneeBarActivityFeature/ActivityDetailView.swift`
- Modify `Tests/SchneeBarActivityFeatureTests/ActivityDetailViewBehaviorTests.swift`

RED:
- status-specific disclosure labels;
- evidence-state icon mapping;
- empty evidence hides disclosure.

GREEN:
- compact DisclosureGroup under Delivery events/unavailable copy.

## Task 7 — Fixtures / visuals / roadmap

Files:
- Modify `Sources/SchneeBarPreviewSupport/ActivityDetailFixtures.swift`
- Modify Visual snapshot coverage if necessary
- Modify `docs/DEVELOPMENT_PLAN.md`

Visual:
- exact evidence;
- missing evidence;
- temporary failure;
- deployment evidence;
- Light/Dark.

Roadmap:
- mark richer confidence/evidence explanations implemented;
- keep recovery notifications and persisted history next.

## Task 8 — Exact-head gate

- CI success.
- Visual Regression success.
- CodeQL success.
- unresolved review threads = 0.
- requested-changes reviews = 0.
- mergeable = true.
- final diff verifies no network/client/permission expansion.

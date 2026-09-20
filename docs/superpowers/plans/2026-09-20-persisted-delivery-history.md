# Persisted Delivery History Implementation Plan

Date: 2026-09-20

Goal: retain normalized Delivery history across restarts using bounded Application Support JSON, without adding GitHub requests.

Spec: `docs/superpowers/specs/2026-09-20-persisted-delivery-history-design.md`

## Constraints

- no new GitHub endpoint/request;
- explicit history live load remains one request;
- no background history collection;
- provider-neutral persisted models;
- no credentials/raw SHA/raw DTOs;
- max 200 entries/scope and 100 scopes;
- persistence errors never hide successful live data;
- network errors fall back to cache when available;
- disconnect cleanup is best effort.

## Task 1 — Codable + Storage Port

Files:
- modify `Sources/SchneeBarCore/DeliveryHistory.swift`
- add Core tests.

RED:
- Codable round trip;
- storage scope equality;
- no-op store behavior.

GREEN:
- add Codable;
- add provider-neutral scope/protocol/no-op adapter.

## Task 2 — Deterministic Merger

Files:
- add `Sources/SchneeBarCore/DeliveryHistoryMerger.swift`
- add tests.

RED:
- cached + live merge;
- live wins duplicate ID;
- deterministic ordering;
- 200 cap.

GREEN:
- pure merger.

## Task 3 — Application Support Store

Files:
- add `Sources/SchneeBarApp/ApplicationSupportDeliveryHistoryStore.swift`
- add App tests.

RED:
- round trip;
- schema mismatch;
- retention;
- multi-source isolation;
- delete source;
- recreate store.

GREEN:
- actor store;
- versioned envelope;
- ISO8601/sorted JSON;
- atomic write;
- 0700/0600 best-effort permissions.

## Task 4 — Runtime Injection

Files:
- modify `GitHubConnectionsRuntimeModel.swift`
- update App initialization/test defaults.

RED:
- default no-op compatibility;
- injected store available to history loader.

GREEN:
- add `deliveryHistoryStore` dependency with no-op default.

## Task 5 — Persisted History Composition

Files:
- modify `GitHubConnectionsRuntimeModel+DeliveryHistory.swift`
- extend runtime history tests.

RED:
- online load persists;
- repeated loads accumulate;
- network failure returns cache;
- Actions unavailable returns cache;
- store read/write failure isolated;
- live request count remains one.

GREEN:
- load cache first;
- one live request;
- deterministic merge;
- best-effort write;
- fallback on live failure.

## Task 6 — Disconnect Cleanup

Files:
- modify runtime disconnect flow;
- tests.

RED:
- disconnect deletes only the current source history;
- cleanup failure does not prevent connection deletion.

GREEN:
- best-effort `delete(sourceID:)`.

## Task 7 — Production Wiring / Roadmap

Files:
- modify `SchneeBarApp.swift`
- modify `docs/DEVELOPMENT_PLAN.md`.

Wire production `ApplicationSupportDeliveryHistoryStore`.

Mark persisted Delivery history implemented.

## Task 8 — Exact-Head Gate

- CI success;
- Visual Regression success;
- CodeQL success;
- review threads = 0;
- requested changes = 0;
- mergeable;
- diff audit confirms no GitHub client/endpoint/polling expansion.

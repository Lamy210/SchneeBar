# Persisted Delivery History — Phase 4 Eighth Vertical Slice

Date: 2026-09-20
Status: Approved for implementation from the continue-development instruction
Stack base: `feat/delivery-recovery-notifications@cd15f23d267ea1d295deca363faa819fd4334b18`

## Purpose

Persist repository-scoped normalized Delivery history locally so history survives app restart, grows beyond the current latest-20 API window over repeated explicit loads, and remains readable during temporary GitHub failures.

This slice keeps history demand-driven. It does not add background history polling or new GitHub requests.

## Storage Choice

Use a versioned JSON file under Application Support.

Why:
- current remote history request is capped at 20 completed Workflow runs;
- access pattern is whole-scope load/merge, not relational querying;
- expected retained volume is small;
- SchneeBar already uses an Application Support, versioned JSON, atomic-write pattern for GitHub connection profiles;
- avoids a new SQLite/SwiftData/GRDB dependency and migration subsystem before query complexity justifies one.

Deferred migration trigger:
- cross-repository filtering/search;
- thousands of entries per source;
- concurrent writers/processes;
- transactional multi-table state;
- analytics/query workloads.

## Core Contract

Make existing normalized models Codable:

```swift
public struct DeliveryHistoryEntry: Identifiable, Codable, Equatable, Sendable
public struct DeliveryHistorySnapshot: Codable, Equatable, Sendable
```

Add provider-neutral storage scope and port:

```swift
public struct DeliveryHistoryStorageScope: Hashable, Codable, Sendable {
    public let sourceID: String
    public let repositoryID: String
}

public protocol DeliveryHistoryStoring: Sendable {
    func load(scope: DeliveryHistoryStorageScope) async throws -> DeliveryHistorySnapshot?
    func save(_ snapshot: DeliveryHistorySnapshot, scope: DeliveryHistoryStorageScope) async throws
    func delete(sourceID: String) async throws
}
```

`sourceID` and `repositoryID` are opaque storage identities. Core does not know GitHub connection/repository types.

Provide a no-op implementation in Core for source compatibility/testing defaults.

## GitHub Scope Mapping

App/runtime maps:
- sourceID = existing GitHub connection UUID string;
- repositoryID = decimal stable GitHub repository ID.

Do not use repository full name as the storage key because the same name may exist across endpoints/accounts and repositories can be renamed.

The stored snapshot still carries its display repository name.

## Persistence Adapter

Add `ApplicationSupportDeliveryHistoryStore` in the App target.

Default file:
`~/Library/Application Support/SchneeBar/delivery-history-v1.json`

Envelope:

```swift
{
  "schemaVersion": 1,
  "records": [
    {
      "sourceID": "...",
      "repositoryID": "...",
      "updatedAt": "...",
      "snapshot": { ... }
    }
  ]
}
```

Requirements:
- actor-isolated;
- JSON dates use ISO-8601;
- sorted keys for deterministic fixtures/debugging;
- atomic writes;
- directory permissions best-effort 0700;
- file permissions best-effort 0600;
- unsupported schema version returns a typed error;
- no credentials, tokens, raw GitHub DTOs, SHA, actor/reviewer identity, or API payloads are stored.

## Retention

Per storage scope:
- deduplicate by `DeliveryHistoryEntry.id`;
- newest incoming entry wins on duplicate ID;
- sort by `occurredAt` descending, then `id` ascending;
- retain at most 200 entries.

Global:
- retain at most 100 scopes;
- records ordered by `updatedAt` descending;
- prune oldest scopes beyond the cap.

These bounds cap memory/disk use while allowing repeated latest-20 loads to accumulate useful history.

## Runtime Load Semantics

Existing explicit history navigation remains the trigger.

After resolving the exact current profile/repository:

1. create storage scope;
2. best-effort load cached snapshot;
3. if Actions is definitively unavailable:
   - return cache when present;
   - otherwise preserve current `actionsUnavailable` error;
4. make the existing exactly-one completed-runs request (`limit: 20`);
5. map GitHub response to provider-neutral live snapshot;
6. merge live + cached using the same deterministic retention policy;
7. best-effort save merged snapshot;
8. return merged snapshot.

On GitHub/network failure:
- return cached snapshot when available;
- otherwise rethrow the existing error.

On persistence read/write failure:
- live GitHub history remains usable;
- persistence failure must not turn a successful network load into a UI error.

## Merge Policy

Add a pure Core helper or store-shared policy:

`DeliveryHistoryMerger(maximumEntries: 200)`

Rules:
- repository display name from live snapshot wins when live data exists;
- otherwise cached repository name remains;
- entry ID is the stable dedup key;
- incoming/live entry wins duplicate conflicts;
- deterministic sort and max-entry bound.

Persistence adapter and runtime tests must share this policy rather than duplicate sorting logic.

## Privacy / Security

Persisted history contains local user-visible metadata already shown in SchneeBar:
- repository display name;
- normalized status/detail/branch text;
- trusted destination URL;
- event timestamp.

It must not persist:
- credentials/tokens;
- raw commit SHA;
- GitHub API response bodies;
- reviewer/actor identity;
- Environment reviewer identity;
- notification payloads.

The file is app support data, not a credential store. Keychain remains the credential boundary.

## Disconnect / Lifecycle

On explicit GitHub connection disconnect:
- best-effort delete all persisted Delivery history scopes belonging to that connection.

On monitoring disable:
- keep persisted history.

On repository deselection:
- keep persisted history; deselection is not deletion.

On provider reset/re-authentication:
- keep persisted history unless the connection itself is deleted.

## Request / Performance Invariants

- explicit history load remains exactly 1 GitHub HTTP request when online and Actions is requestable;
- cached fallback adds 0 GitHub requests;
- Delivery detail remains 12 feature requests;
- recovery notification detection remains 0 additional GitHub requests;
- persistence I/O occurs only on explicit history load and disconnect, never every Activity polling cycle.

## Failure Modes

Corrupt/unsupported persistence file:
- runtime ignores read failure and continues with live GitHub data;
- successful live data may attempt save; if save fails, return live data anyway.

Network outage with cache:
- return cache.

Network outage without cache:
- preserve current error behavior.

Write failure:
- return merged in-memory result; do not fail history presentation.

Disconnect delete failure:
- connection removal still proceeds;
- local cleanup is best-effort.

## Tests

Core:
- Codable round-trip for entry/snapshot;
- scope equality/hash;
- merge dedup/live-wins/order/200 cap.

Persistence:
- empty file => nil;
- save/load round-trip;
- deterministic merge retained across store reconstruction;
- schema mismatch typed error;
- permissions where test environment permits;
- 200-entry per-scope cap;
- 100-scope global cap;
- delete(sourceID:) isolates other sources;
- atomic rewrite preserves decodable file.

Runtime:
- first online load persists;
- second/new process instance returns persisted history;
- repeated latest-20 loads accumulate older unique entries up to 200;
- network failure returns cache;
- Actions unavailable returns cache;
- no cache preserves current errors;
- persistence failure does not hide live result;
- exactly one Workflow request when live request occurs;
- disconnect attempts source cleanup.

Regression:
- current Delivery History visual behavior remains valid;
- existing one-request history budget remains green;
- no Activity polling request increase.

## Acceptance Criteria

- persisted history survives store/runtime recreation;
- repeated explicit history loads can retain more than 20 unique entries;
- no scope exceeds 200 entries;
- no store exceeds 100 scopes;
- temporary GitHub failure can display previously cached history;
- live data wins duplicate IDs;
- no new GitHub requests or background polling;
- disconnect performs best-effort local cleanup;
- CI, Visual Regression and CodeQL pass on the exact implementation head.

## Deferred

- SQLite/SwiftData migration;
- full-text/search/filter history;
- user-configurable retention;
- cross-device sync;
- export/import;
- background history collection;
- persisted recovery-lane state.

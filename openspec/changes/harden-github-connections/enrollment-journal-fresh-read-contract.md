# P0 follow-up: fresh durable enrollment journal reads

## Observed gap
`GitHubCredentialEnrollmentJournal.record(for:)` caches an enrollment after the first durable load. Cross-process writes are serialized and compare-and-swapped by the file persistence adapter; a **cached read**, however, is not a guarantee that an enrollment remains dpActive. For example, another instance may have persisted a disconnect after this actor cached dpActive.

## New behavior
- Add explicit `refreshRecord(for:)` to reload and validate the complete durable journal from its persistence adapter, even when this actor is already loaded. Return the selected enrollment or nil when absent.
- The file adapter's `load()` continues to acquire the shared cross-process lock and validate the whole record collection; this method must not perform Keychain I/O or reveal credential values.
- Discard the previously cached records **before** fetching from persistence. If the read fails or the collection is corrupt/duplicated, fail closed and never use a prior dpActive cache on a subsequent `record(for:)`.
- Preserve the cheaper `record(for:)` for non-authorizing display/lookup and keep all existing transition/CAS semantics unchanged.
- A fresh snapshot is **not** a lease, generation fence or cryptographic proof. Another process can transition immediately after the shared read lock is released. The runtime must still hold or recheck authoritative generation across every credential-using operation and check provider account/App/install identity.

## Deterministic tests
- Two independent journal actors: a cached dpActive record in A becomes disconnected in B; A's `record(for:)` is stale until `refreshRecord(for:)` observes the persisted disconnect.
- Duplicate/corrupt persisted records cause an error, old active cache is discarded, and a subsequent read observes corrected durable state.
- Injected persistence read failure does not return the earlier active generation; a later lookup reloads current disconnected state and unknown IDs return nil.

- Real private-directory file-adapter integration: two journal instances observe a stale cached dpActive, one persists a disconnect using locked atomic replacement, and the other refreshes to observe the disconnected generation. This is a filesystem integration test, not real signed-Keychain evidence.

## Rollout
- No automatic migration, Keychain deletion, token refresh, secret logging, or production runtime wiring.
- macOS CI Build/Test, Visual Regression and OpenSpec strict on the exact PR head; unresolved review comments must be zero before `main` merge. Sync `main` to `integration/schneerunner` in a later reviewed PR.
- P0 #368 remains open pending signed real-Mac DPK behavior, cross-process authorization transaction fencing, identity attestation, crash-safe migration and rollback.

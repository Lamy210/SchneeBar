# Data Protection Keychain: safe V2 foundation

Status: opt-in implementation in a separate PR against `main`. Related: #368, OpenSpec #367. **Not a completed credential migration**.

## What is implemented

- `GitHubCredentialEnrollmentKey` separates V2 read/write authorization records by a fresh immutable enrollment UUID. The account string is `v2:<purpose>:<uuid>` and uses a **different service** from the legacy `GitHubCredentialKey(connectionID, accountID)` storage.
- `DataProtectionGitHubCredentialStore` has a separate opt-in interface (`load`, **insert-only**, exact-record `delete`), not the production `GitHubCredentialStore` interface. The shipping coordinator still uses the existing legacy service. No user credential is migrated, deleted, rotated or silently promoted.
- All V2 item queries explicitly set `kSecUseDataProtectionKeychain=true` and `kSecAttrSynchronizable=false`. New items request `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly` for future background read-only sessions.
- A unit test checks namespace isolation and query construction. The optional real-Keychain smoke uses a unique service + synthetic token and is disabled by default on unsigned CI.

## Apple primary-source basis

- https://developer.apple.com/documentation/security/ksecusedataprotectionkeychain
- https://developer.apple.com/documentation/technotes/tn3137-on-mac-keychains
- https://developer.apple.com/documentation/security/ksecattraccessibleafterfirstunlockthisdeviceonly

These document expected API selection, **not evidence of this app's signed runtime lock/first-unlock behavior**. The latter is deliberately marked unknown pending real-Mac measurement.

## Outstanding #368 gates — before production use

1. Signed app + real user session: DPK availability and first-unlock/locked/background behavior, code signing, entitlement and Keychain access group.
2. Durable enrollment journal binding UUID to canonical origin + numeric account + verified App client ID/purpose; monotonic epoch and disconnect tombstone.
3. Exact legacy Keychain lookup and reserved item migration with read-back/compare, crash/retry and no incorrect old-record deletion.
4. Refresh-rotation coordination/atomic persistence, concurrent process policy, reconnect-to-same-account cleanup, profile/cleanup-ledger integration.
5. Failure fixtures for duplicate V2 insert, exact delete, legacy and DPK coexistence, empty or corrupt stored record, cancellation between every migration phase.

Do not enable V2 for real credentials based on passing unsigned macOS CI alone. The present code is a **narrow foundation** suitable for separate code review.

# Implementation tasks

## Evidence and characterization

- [x] Identify current Keychain/Device Flow/HTTP/session/disconnect/write-control paths by code review.
- [x] Link primary macOS Data Protection Keychain and GitHub token/flow references.
- [ ] Reproduce exact Keychain class/accessibility behavior on a signed real Mac.
- [ ] Determine valid `offline_access` semantics and token expiry data on GitHub.com, GHE.com and tested GHES fixture.

## SEC-001: Keychain

- [ ] Add synthetic regression tests for DPK/legacy lookup, copy/read-back/delete and error paths.
- [ ] Implement `kSecUseDataProtectionKeychain` across all DPK operations with separate exact legacy queries.
- [ ] Implement crash-safe idempotent transition, old token preservation, and user-visible recovery.
- [ ] Verify unlocked/locked/background behavior, codesign/access groups and restart.

## SEC-002: Token issuance and refresh

- [ ] Add expiring issuance request and explicit policy for newly issued hosted credentials.
- [ ] Handle legacy non-expiring / unsupported GHES as explicit migration states; never silently discard.
- [ ] Test malformed/expired refresh, rotation races, endpoint binding and account mismatch.
- [ ] Add no-secret diagnostic logs and UI state tests.

## SEC-003: Network trust

- [ ] Add redirect-aware transport policy for OAuth and authorized REST requests.
- [ ] Test all cross-origin, downgrade and malformed redirect cases with zero redirected secret traffic.
- [ ] Keep existing ephemeral no-cookie/no-cache behavior and test request/response budgets.

## SEC-004–006: Privileges and disconnect

- [ ] Design and test read-only App vs optional write App provisioning and account identity.
- [ ] Enforce capability + confirmed-action authorization at mutation-service boundary.
- [ ] Track partial cleanup and remote revocation separately, eliminating silent history-delete failure.
- [ ] Improve preview Client ID consent clarity; show verified App identity when available.
- [ ] Keep credentials and write clients out of local companion event contracts.

## Release gate

- [ ] Run all synthetic security regression tests and signed real-Mac Keychain tests.
- [ ] Review security diff and migration rollback evidence before any merge.
- [ ] Record measured results and residual risk; do not check off tasks based only on static review.

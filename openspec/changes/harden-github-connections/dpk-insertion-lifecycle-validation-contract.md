# P0 hardening: validate V2 DPK insertion lifecycle before Keychain I/O

## Context
The opt-in Data Protection Keychain V2 store already validates an exact credential endpoint and bounded token shape. Its read path reconstructs the enrollment identity to reject malformed Codable snapshots, but its insert-only path did not reconstruct that identity and accepted any positive generation in `prepared` or `migrationPrepared`. A future caller that passes a decoded or malformed lifecycle must not stage credentials under an impossible registration state.

## Contract
- Before any V2 `SecItemAdd`, require `prepared` at exactly generation 1, or `migrationPrepared` with generation >=2. Reject `dpActive`, `refreshInFlight`, `disconnected`, `reauthRequired`, `legacyActive` and forged phase/generation combinations.
- Reconstruct the enrollment domain identity before writes: valid HTTPS origin without embedded credentials/query/path, strictly positive canonical numeric account ID, and a nonempty trimmed client ID without control characters. Share that structural validation with V2 `loadActive` rather than allowing read/write policies to drift.
- Preserve exact credential endpoint binding and opaque token validation; do not add any Keychain operations to the pure validator.
- Keep insert-only behavior, existing V2 service/key addresses, legacy store, raw readback for migration staging and signed Mac smoke opt-in unchanged. This is **defense in depth**, not evidence of real-world token exposure.

## Tests
- Reconstruct malformed Codable snapshots with HTTP origin, nonnumeric account and empty client ID; confirm the insert policy fails with `invalidEnrollmentIdentity`.
- Reject forged `prepared` generation 2 and `migrationPrepared` generation 1; allow legitimate prepared generation 1 and migrationPrepared generation 2.
- Existing DPK insertion/read and migration tests must remain green. macOS CI, Visual Regression, and OpenSpec strict validation are required on the final PR head.

## Not guaranteed
A syntactically valid enrollment is not proof of journal freshness or actual GitHub account/App binding. Future runtime integration must still use authoritative journal generation fencing throughout credential operations. Signed real-Mac Keychain lock/unlock, secret migration/rollback and refresh rotation remain unverified under P0 #368.

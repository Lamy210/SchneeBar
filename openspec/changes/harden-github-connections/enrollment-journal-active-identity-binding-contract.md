# P0 V2 enrollment preflight: bind the active generation to an exact account/App identity

## Gap
The V2 journal already supports `requireFreshActiveRecord(for:expectedGeneration:)`, which rereads durable metadata and rejects stale generations/inactive phases. However, a generation+enrollment UUID alone is insufficient to assure that the caller's expected purpose, web origin, numeric GitHub account ID and App client ID are the same as the persisted enrollment. A future caller could accidentally use an active enrollment for the wrong provider scope.

## Scope and behavior
- Add a new `requireFreshActiveRecord(matching:)` overload that takes a caller-supplied lifecycle snapshot. Reuse the existing durable generation and `dpActive` check **exactly once**, then compare the caller's expected `purpose`, `canonicalWebOrigin`, `numericAccountID`, and `appClientID` against the validated persisted record.
- If the expected generation is stale, use existing `staleSnapshot`; if missing use `missingEnrollment`; if current/expected phase is not active, use `inactiveEnrollment`. If the bound identity differs at the same active generation, reject with `enrollmentIdentityMismatch`. Never return secrets or log private identity fields.
- Preserve existing key derivation, credential storage, journal append-only transitions, cached UI lookup, and legacy sessions. This is a pure read-only preflight API, not connected to shipping authorization.

## Deterministic verification
- With a valid durable dpActive record at generation 2, exact expected snapshot succeeds. Forge a same-ID, same-generation Codable snapshot that changes each of the four identity/scope fields independently; every case rejects with `enrollmentIdentityMismatch` while the stored record remains unchanged.
- Prepared/not-dpActive expected snapshots reject; an expected generation older than a durable disconnect fails closed.
- File-backed journal actors sharing one secure directory: active exact scope accepted, a forged numeric account at the same epoch rejected, then a durable external disconnect causes the old active expectation to reject.

## Constraints
The snapshot matching function is a *point-in-time identity/scope comparison*, not proof of the live GitHub user, App installation, token binding or an atomic Keychain operation lease. A later transition can race with any caller after return. Real authorization must verify the GitHub provider identity and fence generation through the credential-using operation. Signed real-Mac Keychain behavior, refresh rotation, migration/rollback and production connection wiring are separate P0 #368 acceptance gates.

Required before main merge: macOS CI Build/Test with three new tests passing, Visual Regression, OpenSpec validation and zero unresolved review threads. Synchronize to integration in a separate reviewed PR.

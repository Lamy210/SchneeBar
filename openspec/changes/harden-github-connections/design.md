# Design: GitHub credential and API trust boundary

## Existing baselines

- Keychain actor: `Sources/SchneeBarGitHubKeychain/KeychainGitHubCredentialStore.swift`
- Device Flow + refresh: `Sources/SchneeBarGitHub/GitHubDeviceFlow.swift`
- Session coordination / endpoint binding / refresh single-flight: `Sources/SchneeBarGitHub/GitHubConnectionSessionCoordinator.swift`
- Ephemeral HTTP: `Sources/SchneeBarGitHub/GitHubHTTPTransport.swift`
- Workflow mutations: `Sources/SchneeBarGitHub/GitHubWorkflowRunMutationService.swift`
- Disconnect/profile cleanup: `Sources/SchneeBarApp/GitHubConnectionsRuntimeModel.swift`

## Keychain migration algorithm

1. Feature-gate new DPK store and identify expected `service + account` key. Never enumerate unrelated Keychain secrets.
2. Read new DPK item using `kSecUseDataProtectionKeychain=true`. If absent, attempt exact legacy lookup without DPK flag.
3. Validate decoded credential shape, canonical endpoint binding/account identity and lifetime rules appropriate to its legacy status; ambiguous credentials require reauthentication.
4. Write a **new** DPK item with `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly` for background read-only monitoring and non-synchronizing behavior. Preserve service/account identity mapping unless migration requires namespacing.
5. Read back and compare credential metadata and secret equality in memory; only then delete the expected legacy entry. All error paths preserve the source and surface retry.
6. Test both success and crash windows and ensure disconnected credentials are not resurrected.
7. Consider separate `WhenUnlockedThisDeviceOnly` storage for write credentials **only after** signed-app UX/integration tests; no silent change to existing background refresh behavior.

## Expiring tokens

- For tested hosted GitHub App instances, include the GitHub-documented expiring token request semantics (`offline_access`) at initiation and require expiry fields on newly issued credentials.
- Distinguish existing legacy non-expiring credentials and tested GHES instances; never silently delete working credentials on policy rollout. Prepare explicit migration/reconnect UX.
- Refresh tokens atomically using the existing coordinator's single-flight policy; preserve endpoint and stable numeric account identity binding. An expired or malformed token must not reach network when validation already proves it invalid.
- Validate GitHub App owner/publisher where API evidence allows; display unknown/unverified rather than claiming verification.

## HTTP redirect policy

- Build an origin-policy-aware transport wrapper for OAuth code/refresh and bearer API routes. Reject unsolicited redirects of sensitive requests; never automatically replay a POST body/Authorization header to a new host.
- Test 30x responses by injecting `URLProtocol` or an equivalent deterministic transport and explicit redirect delegate. Include HTTPS downgrade, different host, port, userinfo, malformed Location, encoded host and known same-origin redirects.
- Existing URLSession ephemeral cookie/cache settings remain. Do not log requests with token-bearing headers/body.

## Permissions and app scopes

- Keep read-only connection usable without Actions(write). Separate write-capable GitHub App/credential is preferred over a mere local toggle.
- Authoritative per-repository write check at the mutation service, in addition to existing UI check and confirmation; reject unknown/capability unavailable.
- A local build event, distributed notification, character pack or external widget must not be able to reach a write API by graph construction.
- GitHub user access token scopes are limited by GitHub App configuration **and** user repository permission. Distinguish that from a UX-level visibility filter.

## Disconnect and incident recovery

- Token deletion, connection profile removal and local history deletion produce separately observed results. Mark cleanup pending on failure; never hide with `try?` or claim full cleanup.
- Remote GitHub App authorization revocation is not the same operation. Provide official GitHub Applications link where no verified revocation API is usable without a backend/client secret.
- Token suspected stolen: stop local polling, delete local item, guide user to GitHub-side revocation and audit of installed Apps, PATs, SSH keys and sessions.

## Security invariants

No client secret/private key in repo or binary; TLS validation enforced; bounded input and output; no credentials in UI/domain/companion event objects; no accidental privilege change from an integration feature. Keep ADR-0002 unless explicitly replaced after separately reviewed broker threat model.

## Security model and decisions

Trust boundaries: User ⇄ trusted external browser GitHub authorization; GitHub REST/OAuth HTTPS origin ⇄ network transport; app-owned connection profile ⇄ Keychain stored secret; explicitly confirmed UI mutation ⇄ write-capable GitHub API. Local Distributed Notifications, character packs and external widgets are untrusted data and never cross into the mutation authorization boundary.

Decisions:
- Keep ADR-0002 Device Flow without mandatory broker; improving phishing guidance is a mitigation, not an elimination of Device Flow's inherent remote-phishing weakness.
- Use exact origin-account-bound Keychain record lookup. Legacy migration must be **recoverable**, not a cleanup step before validated reauthentication.
- Separate read-only GitHub App authority from opt-in write-capable authority; a settings toggle cannot reduce an already-issued token's server-granted permissions.
- Use request-layer redirect protection for both OAuth body parameters and bearer headers. Maintain HTTPS certificate verification; avoid unsupported certificate-bypass switches for GHES.
- Do not infer GitHub account passkey/2FA state, App publisher, or remote grant revocation from insufficient API evidence.

## Data, state and error contracts

Connection identity key: deployment kind, canonical HTTPS origin and stable numeric GitHub account ID. Connection IDs are app-local UUIDs and cannot substitute for account identity. Treat any mismatch at credential reload/recovery as reauthentication required with no token traffic to newly supplied origin.

Credential health states: `usable`, `refreshRequired`, `reauthenticationRequired`, `unsupportedEnterpriseBehavior`, `connectionDisabled`. Store must never expose `accessToken`/ `refreshToken` to generic UI and must serialize rotated credential updates.

Cleanup health states: `localRemoved`, `localCleanupPending`, `localCleanupFailed`, `remoteRevocationUnknown`; do not conflate them. Disconnect UI distinguishes local removal from the actual GitHub App authorization state.

**Failure handling**: 401 → reauthentication state; explicit SSO evidence → SSO state; ambiguous 403/404 → insufficient evidence rather than claiming SSO; expired/invalid refresh → no repeated polling; network/429 → bounded backoff; user cancel → stop polling and discard candidate credential. Security failures use bounded redacted diagnostics.

## Risks / Trade-offs

- Keychain protection type migration can change background availability → prove DPK and existing OS behavior on a signed Mac; keep legacy fallback only while migration is pending.
- GHES versions may not honor hosted token expiry contract → verify supported matrix and choose explicit compatibility/reauthentication state, not fabricated metadata.
- Device Flow phishing persists → only trusted initiation, host display and strong anti-phishing guidance; reconsider with a separate broker ADR if supported.
- Write App provisioning may be less convenient → default read-only; offer explicit step-up workflow rather than hidden broad access.
- Remote grant cannot be revoked safely by a secretless local public client in all cases → link GitHub's authoritative management UI.

## Migration Plan and rollback

1. Add deterministic no-secret characterization fixtures; ensure existing tests pass.
2. Implement DPK read/write as a separate store strategy behind an enablement gate.
3. Verify migrated item read-back and exact endpoint/account identity before legacy deletion; test power loss/retry windows.
4. Enable expiring-token policy only with per-deployment evidence; allow explicit legacy recovery.
5. Gate mutating operations behind separately scoped authority and user confirmation.
6. Roll back to previously stored validated credentials when safe, or require reauthentication rather than reusing ambiguous or leaked tokens.
7. Do not enable GitHub→Companion event routing until all relevant P0 evidence and security reviews are complete.

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

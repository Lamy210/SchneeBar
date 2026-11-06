## Purpose
This capability protects GitHub account tokens, account identity, network destinations and optional repository mutations so local-first connections survive expiration and migration without exposing credentials or silently expanding access.

## ADDED Requirements

### Requirement: Keychain credentials use verified macOS protection with recoverable migration

The app SHALL store GitHub secrets in an intended Keychain protection domain, verify its actual macOS accessibility behavior, and migrate old records without destroying valid original credentials before a successful read-back.

#### Scenario: Legacy credential exists
- **WHEN** a valid old credential is found and no current DPK record exists
- **THEN** migration SHALL validate endpoint/account binding, write a new protected record, read and verify it, and only then delete the exact legacy credential.

#### Scenario: Migration write fails
- **WHEN** writing or read-back verification of the new credential fails
- **THEN** the source SHALL remain recoverable and the UI SHALL surface a failure without claiming success.

### Requirement: New GitHub credentials are expiry-aware

For verified supported GitHub App deployments, the app SHALL request expiring credentials, validate issuance/refresh metadata and treat malformed or expired credentials as reauthentication-required without sending them as bearer tokens.

#### Scenario: New token lacks required expiry data
- **WHEN** an owned hosted GitHub App responds with a non-expiring token payload contrary to the selected policy
- **THEN** the connection SHALL fail securely without persisting that newly issued credential.

#### Scenario: Legacy credential predates the policy
- **WHEN** an existing non-expiring credential is loaded during rollout
- **THEN** the app SHALL follow an explicit migration/reauthentication path rather than silently discarding or misclassifying it.

### Requirement: Secret-bearing HTTP requests cannot redirect outside their approved origin

The network adapter SHALL prevent automatic following of unexpected redirects for requests containing bearer credentials, OAuth device codes, refresh tokens or client-authentication material.

#### Scenario: Cross-origin redirect
- **WHEN** an authenticated API or OAuth request receives an HTTP redirect to another origin
- **THEN** the adapter SHALL reject it and SHALL send zero secret-bearing requests to the redirected destination.

### Requirement: GitHub writes require independent authorization

A GitHub write-capable operation SHALL require verified repository capability and an explicit interactive authorization pathway; it SHALL never be triggered by an untrusted local event or an external widget.

#### Scenario: Read-only connection attempts CI cancel
- **WHEN** a user or injected event attempts to cancel a workflow with read-only permissions
- **THEN** zero GitHub workflow mutation requests SHALL be sent.

### Requirement: Disconnect reports local and remote outcomes truthfully

The app SHALL distinguish local token/profile/history removal, cleanup pending or failed and GitHub-side App authorization status.

#### Scenario: History cleanup fails
- **WHEN** token and profile deletion succeed but local history deletion fails
- **THEN** the app SHALL retain a visible cleanup-failed/pending status and SHALL NOT claim that all local data has been deleted.

#### Scenario: Local disconnect with remote authorization still active
- **WHEN** local credentials are deleted without verified GitHub-side revocation
- **THEN** the UI SHALL state that remote access may remain authorized and provide a path to GitHub Applications settings.

### Requirement: Token refresh and account recovery cannot cross identities

The app SHALL bind each persisted credential to a canonical GitHub origin and stable numeric GitHub account identifier and SHALL preserve refresh-token single-flight behavior during concurrent access.

#### Scenario: Two requests need the same refresh token
- **WHEN** two concurrent requests need a refresh for the same connection and account
- **THEN** at most one refresh-token exchange SHALL be initiated for the active generation and both requests SHALL use a valid resulting credential or receive recovery status.

#### Scenario: Persisted connection endpoint changes
- **WHEN** a saved connection endpoint differs from the endpoint bound to its credential
- **THEN** the app SHALL NOT send that credential to the changed endpoint and SHALL request safe recovery.

#### Scenario: Account changed during reauthentication
- **WHEN** GitHub authenticates a different numeric account than the account being recovered
- **THEN** the app SHALL keep the original credential/profile untouched and SHALL NOT silently swap the identity.

### Requirement: Unsupported enterprise expiry semantics fail explicitly

The app SHALL apply token-expiration rules only where supported by verified hosted or enterprise-server evidence and SHALL expose unsupported or untested behavior as an explicit compatibility state.

#### Scenario: Enterprise server does not support verified expiry behavior
- **WHEN** a tested enterprise instance cannot satisfy the selected expiring-token policy
- **THEN** the app SHALL NOT fabricate expiry metadata or silently replace a functioning existing credential; it SHALL present a documented compatibility or recovery path.

### Requirement: Authorized requests reject downgrade and unapproved redirects

The app SHALL prevent secret-bearing HTTP requests from being replayed to an unapproved destination or downgraded from HTTPS, even if a server returns an HTTP redirect.

#### Scenario: Redirect to HTTP or new port
- **WHEN** an OAuth or authenticated API request receives a redirect to HTTP or an unapproved port
- **THEN** the app SHALL stop the request and SHALL send no secret-bearing traffic to the new destination.

### Requirement: Authentication material is excluded from diagnostics

The app SHALL ensure that access tokens, refresh tokens, device codes and authorization headers are not included in logs, exported diagnostics or companion event payloads.

#### Scenario: Provider returns an authentication error
- **WHEN** the provider returns a failed authorization or token-refresh response
- **THEN** logs SHALL contain only bounded nonsecret status and SHALL NOT include raw authentication material.

### Requirement: Credential migration and refresh have durable generation fencing

The app SHALL serialize or durably fence migration, token refresh, profile recovery and disconnect for each credential identity, SHALL preserve the current epoch after restart, and SHALL prevent stale asynchronous work from persisting or sending a disconnected credential.

#### Scenario: Refresh completes after disconnect
- **WHEN** a refresh succeeds after the user disconnects and the epoch is invalidated
- **THEN** the returned token SHALL NOT be persisted or used, and the disconnected tombstone SHALL remain authoritative.

#### Scenario: Migration races an active refresh
- **WHEN** DPK migration and OAuth token refresh target the same account and App identity concurrently
- **THEN** the app SHALL serialize their committed updates to one current epoch, SHALL NOT overwrite a newer rotated token with older legacy bytes, and SHALL keep a recoverable state.

#### Scenario: Crash after DPK readback
- **WHEN** the app crashes after staging a readable DPK item but before a durable promotion marker
- **THEN** restart SHALL reconcile only the current generation and SHALL NOT select an uncommitted item as authoritative.

#### Scenario: OAuth rotation succeeds before durable storage
- **WHEN** GitHub invalidates an old refresh token and the client crashes before saving its replacement
- **THEN** the app SHALL require explicit reauthentication rather than promise that its persisted legacy token can still be refreshed.

### Requirement: Write grants are independently bound and explicitly invoked

The app SHALL use a distinct, verified write-authorization record and Keychain namespace from the read connection, SHALL bind it to the intended GitHub App, origin and account, and SHALL require a single-use user-confirmed operation intent plus current repository capability evidence at the mutation service.

#### Scenario: Legacy read App has Actions write permission
- **WHEN** an existing read connection has server-granted Actions write permission but no separately enrolled write grant
- **THEN** the app SHALL keep read activity functional but SHALL send zero workflow mutation HTTP requests.

#### Scenario: Different account or repository in intent
- **WHEN** the write App account, installation or repository evidence differs from the current action target
- **THEN** the mutation service SHALL reject the operation before network I/O.

#### Scenario: Untrusted character event attempts to reuse confirmation
- **WHEN** a local event attempts to replay a consumed or expired user intent
- **THEN** the app SHALL send zero GitHub workflow mutation HTTP requests.

### Requirement: Local cleanup failure state survives connection removal

The app SHALL persist profile-independent nonsecret step outcomes for local token, profile and history deletion before normal disconnect and SHALL support safe retry after relaunch without re-creating a credential.

#### Scenario: History delete fails after profile deletion
- **WHEN** token and profile deletion succeed but history deletion fails and the app restarts
- **THEN** a global cleanup screen SHALL show a pending failure for the original source ID and SHALL permit retry without restoring the profile or contacting GitHub.

#### Scenario: Previous cleanup coexists with new connection
- **WHEN** a user reconnects to the same GitHub account while old history cleanup is pending
- **THEN** retry SHALL remove only the old source ID data and SHALL NOT delete the new profile or its activity history.

#### Scenario: Cleanup ledger cannot be saved
- **WHEN** the app cannot durably record the normal disconnect intent
- **THEN** it SHALL NOT report that a recoverable full cleanup has started; an explicitly warned emergency local token deletion MAY remain available.

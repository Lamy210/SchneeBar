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

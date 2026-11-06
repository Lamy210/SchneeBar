# Spec Delta

## Purpose

Provide account-connection and recovery interfaces that help users recognize intended GitHub authorization, distinguish locally stored credentials from remote grants, and make security-relevant connection decisions with truthful evidence.

## ADDED Requirements

### Requirement: Connection initiation identifies the intended authorization

Before requesting authorization, the app SHALL display the selected GitHub host and the GitHub App identity and permission evidence that it can actually verify.

#### Scenario: Unknown preview Client ID
- **WHEN** a user supplies a GitHub App Client ID without verifiable publisher or permission details
- **THEN** the UI SHALL label that evidence unknown and SHALL NOT claim the App is trusted or owned by SchneeBar.

#### Scenario: Wrong GitHub host
- **WHEN** the configured authentication host does not match the validated canonical connection host
- **THEN** authorization SHALL stop before presenting a link or sending an authorization request.

### Requirement: Device authorization includes anti-phishing guidance

The app SHALL show a one-time code, the canonical GitHub authorization host, and explicit guidance to approve only flows initiated inside the app.

#### Scenario: User starts a new Device Flow
- **WHEN** a user initiates GitHub connection from SchneeBar
- **THEN** the UI SHALL show the verification destination, one-time code and a warning not to approve codes received through messages or other apps.

#### Scenario: User cancels authorization
- **WHEN** a user cancels an outstanding authorization
- **THEN** the client SHALL stop polling that session and SHALL NOT store a newly received credential from the canceled attempt.

### Requirement: Multi-account connections preserve exact identity

The app SHALL display the authenticated account and canonical connection host and SHALL reject replacing a saved connection with a different account without an explicit new connection choice.

#### Scenario: Recovery authorizes another account
- **WHEN** an existing connection starts recovery and GitHub identifies a different numeric account ID
- **THEN** recovery SHALL fail closed without replacing the old account's credential or repository selection.

#### Scenario: Two accounts share one host
- **WHEN** a user connects a second authorized GitHub identity on the same host
- **THEN** it SHALL appear as a separate connection with independently managed repositories and tokens.

### Requirement: Security and disconnect states are truthful

The interface SHALL distinguish verified connection status, unverified account-security settings, local data cleanup, and remote GitHub authorization. It SHALL provide incident-response and GitHub authorization-management guidance.

#### Scenario: Local disconnect succeeds
- **WHEN** the user removes local credentials and profile but remote authorization was not verified revoked
- **THEN** the UI SHALL NOT say remote access is revoked and SHALL provide the official GitHub application management destination.

#### Scenario: Cleanup is incomplete
- **WHEN** local credential removal succeeds but activity-history deletion fails
- **THEN** the UI SHALL retain a visible cleanup-pending or failed state with a safe retry.

#### Scenario: GitHub account security cannot be inspected
- **WHEN** GitHub API evidence does not establish whether passkeys or 2FA are active
- **THEN** the UI SHALL report the setting as not verified rather than marking it secure.

### Requirement: Cleanup is visible without the deleted profile

The app SHALL display unfinished local cleanup in a global Security/Cleanup location, independently of whether the old connection profile still exists.

#### Scenario: Profile is already removed
- **WHEN** a user opens Security/Cleanup after a failed history deletion and the original connection row is gone
- **THEN** the pending operation SHALL remain visible with its safe retry action and a truthful local-versus-remote authorization explanation.

#### Scenario: Ledger retry succeeds
- **WHEN** a pending historical cleanup is retried after a restart and all remaining steps succeed
- **THEN** the UI SHALL show local cleanup complete while SHALL NOT claim remote GitHub App authorization was revoked.

### Requirement: Permission migration impact is visible before strict write cutover

The interface SHALL distinguish previously allowed workflow mutations from new separately authorized write operations, explain how to enroll a write App where verified support exists, and SHALL NOT present unsupported GitHub hosts as automatically recoverable.

#### Scenario: Existing user lacks a write App
- **WHEN** strictWriteGrantV2 is enabled for a previously write-capable user's read connection
- **THEN** the UI SHALL clearly explain why rerun/cancel is unavailable and SHALL leave activity monitoring usable.

### Requirement: History cleanup reports irrecoverable parsing failures

The Security/Cleanup interface SHALL distinguish retryable local history cleanup from a blocked unsafe/corrupted shared store and SHALL never offer destructive all-account purge without explicit informed user consent.

#### Scenario: Corrupt shared history blocks cleanup
- **WHEN** a history cleanup fails repeatedly because the shared JSON cannot be safely loaded
- **THEN** the UI SHALL show a persistent blocked state, SHALL not claim complete deletion, and SHALL offer non-destructive recovery guidance.

#### Scenario: User declines deleting all account histories
- **WHEN** the user declines an explicit destructive whole-history purge
- **THEN** the app SHALL keep the file unchanged and SHALL leave the cleanup ledger incomplete and visible.

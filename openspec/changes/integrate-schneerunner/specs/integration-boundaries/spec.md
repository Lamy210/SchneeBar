## Purpose
The integration boundary capability provides stable, credential-free signals and shared macOS services so existing SchneeBar system widgets, GitHub activity, optional Companion and Focus features can coexist without privilege or polling duplication.

## ADDED Requirements

### Requirement: Shared system metrics have a single platform owner

System host CPU sampling SHALL be acquired once and projected separately into widget display and companion policy. Host CPU utilization, smoothed CPU utilization and Activity Monitor per-process `% CPU` SHALL not be presented as interchangeable metrics.

#### Scenario: Widget and companion both subscribe
- **WHEN** the user enables CPU widget and CPU-reactive character
- **THEN** exactly one application-owned sampler SHALL collect the host counter per configured interval and distribute typed samples to both consumers.

#### Scenario: Counter regression
- **WHEN** a cumulative host CPU counter regresses
- **THEN** the current sample SHALL be invalidated rather than emitting a misleading utilization spike.

### Requirement: Credentials and activity are separated

The integration SHALL preserve SchneeBarGitHub as the privileged credential/API owner and project only validated, bounded, credential-free activity into companion state.

#### Scenario: Provider emits a workflow failure
- **WHEN** a GitHub workflow failure is observed from a validated connection
- **THEN** a sanitized signal MAY update companion state without exposing access tokens, refresh tokens, repository secrets or a GitHub write-capable object.

### Requirement: Feature failures do not cascade

Optional features SHALL have independent lifecycle and observable failure state.

#### Scenario: GitHub auth expires
- **WHEN** a connected GitHub token becomes unusable
- **THEN** GitHub surfaces SHALL request reauthentication and Companion/Productivity SHALL remain operational.

#### Scenario: Recoverable renderer or asset error
- **WHEN** a character asset fails to decode or a renderer reports a recoverable error
- **THEN** the app SHALL stop only the affected Companion playback and SHALL fall back to a safe icon or hidden renderer without losing the main menu-bar interface.

#### Scenario: Fatal application process crash
- **WHEN** the whole application terminates from an unhandled fatal error
- **THEN** the app SHALL NOT claim in-process crash isolation; on subsequent launch it SHALL permit disabling the failing Companion feature without changing saved GitHub credentials.

### Requirement: GitHub activity signals are bounded and private

The app SHALL project developer events into character status using only allowlisted event kinds, bounded identifiers and timestamps; raw credentials, arbitrary URLs and private repository payloads SHALL not be exposed.

#### Scenario: Provider sends malformed activity
- **WHEN** the provider emits an oversized identifier, unsupported signal kind or missing trusted connection identity
- **THEN** the projection SHALL reject the signal and SHALL NOT start character or GitHub write actions.

### Requirement: Stale or canceled activity cannot change current character state

The app SHALL scope asynchronous developer activity projections to the current connection generation and discard stale results after reconnection or disablement.

#### Scenario: Connection disabled during load
- **WHEN** a GitHub request completes after its connection was disabled
- **THEN** the result SHALL not produce a new developer reaction or restore a removed connection.

### Requirement: Core system metrics have explicit units

The app SHALL distinguish host-wide raw CPU usage, smoothed host CPU usage and per-process CPU statistics in any display or diagnostic contract.

#### Scenario: Activity Monitor comparison
- **WHEN** a user compares system CPU widget values with Activity Monitor process CPU
- **THEN** the app SHALL label the differing measurement scope rather than imply that these percentages should match.

### Requirement: Local event ingress is bounded before decoding

The app SHALL treat Distributed Notifications as untrusted, SHALL check raw UTF-8 size before JSON materialization, SHALL limit aggregate accepted event rate and active channels, and SHALL expire state without granting API-write authority.

#### Scenario: Raw payload exceeds byte cap
- **WHEN** a local event exceeds 4096 UTF-8 bytes before decoding
- **THEN** the adapter SHALL reject it without allocating an unbounded JSON model or changing character state.

#### Scenario: Event storm exceeds update rate cap
- **WHEN** the thirteenth set/update arrives within a rolling one-second window or the sixty-fifth local channel would be active
- **THEN** the adapter SHALL reject the excess update, preserve terminal-event capacity, maintain bounded accounting and SHALL NOT invoke any GitHub mutation.

#### Scenario: Clear after a full set-event window
- **WHEN** a clear arrives for an active local channel after all 12 update slots are consumed but fewer than four termination slots are used
- **THEN** the adapter SHALL process the clear immediately without treating the update-rate limit as authorization to retain stale display state.

#### Scenario: Clear flood exceeds terminal reserve
- **WHEN** a fifth valid clear/cancel exceeds the reserved terminal slots in a rolling second
- **THEN** the adapter SHALL remove all untrusted local volatile triggers, quarantine further local events until the window resets, and SHALL NOT affect GitHub/Focus state.

#### Scenario: Raw local event storm exceeds ingress limit
- **WHEN** 129 or more local payload callbacks arrive within one rolling second
- **THEN** the adapter SHALL apply constant-work fail-closed quarantine before further JSON decoding, SHALL clear only untrusted local volatile reactions, and SHALL NOT retain an unbounded queue.

#### Scenario: Build-start event never receives terminal state
- **WHEN** a local build started state remains unrenewed beyond 1800 seconds
- **THEN** the trigger SHALL expire rather than continue indefinitely.

#### Scenario: Untrusted event attempts notification handoff
- **WHEN** a distributed notification claims that the source Runner disabled its reminder schedule
- **THEN** the app SHALL NOT treat this unverified message as an authorized migration acknowledgement.

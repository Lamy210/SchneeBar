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

#### Scenario: Character renderer crashes or fails to load asset
- **WHEN** a character asset cannot load
- **THEN** the app SHALL fall back to a safe icon/hidden renderer without losing the main menu-bar interface.

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

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

## Purpose
The companion capability gives users safe, optional animated characters in the menu bar or on the desktop, reacting to validated local and developer events without gaining access to GitHub credentials or write operations.

## ADDED Requirements

### Requirement: Optional companion presentation without duplicate app lifecycle

The integrated app SHALL provide optional menu-bar and desktop character presentation while retaining SchneeBar as the sole `NSStatusItem` and app lifecycle owner. Companion SHALL be disabled without changing GitHub connection state.

#### Scenario: Character disabled
- **WHEN** a user disables Companion
- **THEN** the app SHALL stop Companion animation timers and desktop windows, preserve other widgets and GitHub monitoring, and retain selected character preferences.

#### Scenario: Desktop character enabled
- **WHEN** a user enables the desktop renderer
- **THEN** it SHALL render independently of menu-bar widget visibility and SHALL NOT create another status item.

### Requirement: Character assets remain bounded untrusted data

The companion SHALL validate supported Character Pack assets, formats, path confinement, symlink avoidance and resource budgets before committing a canonical owned copy.

#### Scenario: Malicious or oversized imported pack
- **WHEN** a pack contains a symlink, path traversal, unsupported format, or exceeds defined decode budgets
- **THEN** import SHALL fail with no partial owned library and no execution of imported content.

### Requirement: Reactions are deterministic, prioritized and non-privileged

The companion SHALL map CPU/system/local/developer events to a bounded state trigger with priority, TTL, cooldown and explicit provenance. Triggers SHALL have no API-write capability.

#### Scenario: Untrusted event requests a workflow action
- **WHEN** a local state/build event contains a command-like payload or forged GitHub status
- **THEN** it SHALL NOT invoke any GitHub mutation, credential lookup or network write.

#### Scenario: Repeated CI event
- **WHEN** a duplicate workflow result arrives within its cooldown
- **THEN** it SHALL NOT endlessly restart a reaction animation or flood notifications.

### Requirement: Accessibility and power usage are first class

The companion SHALL honor Reduce Motion, user opt-out and background suspension; non-rendering modes SHALL not continuously decode frames.

#### Scenario: Reduce Motion enabled
- **WHEN** the system Reduce Motion preference becomes active
- **THEN** character playback SHALL reduce or freeze animation without hiding critical textual status.

### Requirement: Character rendering remains usable when assets are unavailable

The app SHALL preserve the core menu-bar interface if a character file is unavailable, malformed, or removed after import.

#### Scenario: Selected asset no longer exists
- **WHEN** the selected character's source file is missing during startup
- **THEN** the app SHALL display a safe fallback state and SHALL keep the dashboard, timers and account connections functional.

### Requirement: Reactions honor user privacy preferences

The app SHALL allow users to disable developer-triggered character reactions independently of GitHub activity monitoring.

#### Scenario: Developer reactions disabled
- **WHEN** a workflow failure is received while developer reactions are disabled
- **THEN** the character SHALL not change because of that workflow and GitHub monitoring SHALL continue independently.

### Requirement: Fatal crashes are not mislabeled as isolated renderer failures

The app SHALL recover safely from handled renderer/asset failures but SHALL NOT guarantee that unrelated UI remains live during an unhandled fatal process crash in the same process.

#### Scenario: Renderer returns an invalid frame
- **WHEN** a Companion renderer rejects a frame with a recoverable error
- **THEN** the app SHALL stop that animation and SHALL retain the main menu-bar UI.

#### Scenario: Safe recovery after process restart
- **WHEN** the user relaunches after an application crash correlated with Companion playback
- **THEN** the app SHALL provide a safe option to keep Companion disabled while retaining settings and GitHub connection state.

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

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

### Requirement: Character playback preserves user control and clip timing

The app SHALL keep manual character selection higher priority than automatic reactions and SHALL keep playback rate separate from resolved state, preserving relative authored frame durations. Returning to Automatic SHALL remove only the manual override. The app SHALL avoid restarting an unchanged clip solely because its trigger changed.

#### Scenario: Manual override released during a local reaction
- **WHEN** a manual state is selected during an active local reaction and then Automatic is selected
- **THEN** the active valid reaction SHALL resume precedence without discarding unrelated triggers or restarting an unchanged clip.

#### Scenario: Desktop movement restored after relaunch
- **WHEN** the app launches with a previously visible desktop character and autonomous movement had been enabled
- **THEN** it SHALL restore supported visibility and safe placement but SHALL leave autonomous movement disabled until explicitly enabled again.

#### Scenario: Menu renderer hidden while desktop remains visible
- **WHEN** the menu character is hidden while the desktop character remains enabled
- **THEN** menu-specific frame work SHALL stop and the desktop renderer SHALL remain usable; hiding both SHALL stop frame scheduling and ongoing decoding.

### Requirement: Companion trigger resolution is deterministic and bounded

The companion SHALL resolve state using fixed source-derived priorities (manual 1000, local/build/productivity/developer event 500, system event 400, system advisory 300, CPU 100). The most recently accepted trigger at the same priority SHALL win, with run as the empty fallback. The domain SHALL use normalized typed identities rather than raw external strings or caller-selected numeric priorities.

#### Scenario: Manual override and equal-priority reactions
- **WHEN** CPU walk, a system advisory, two distinct local events and a manual idle override are accepted in order
- **THEN** manual idle SHALL win; clearing manual SHALL reveal the newest eligible local event and clearing that event SHALL reveal the older eligible event.

#### Scenario: Expiry and renewal at a monotonic boundary
- **WHEN** a trigger is renewed before its prior deadline and resolution is requested at the prior deadline
- **THEN** the renewed trigger SHALL survive until its current deadline; at or after its current deadline it SHALL expire, and an earlier timestamp SHALL NOT resurrect it.

#### Scenario: Capacity limit and manual control
- **WHEN** the proposed domain cap of 126 non-manual/non-CPU triggers is reached
- **THEN** new nonreserved identities SHALL be rejected without eviction; existing identities may be renewed and manual/CPU singleton slots and explicit clears SHALL remain available. At most 64 of those 126 entries SHALL be untrusted local/build triggers combined.

#### Scenario: Local event without a deadline
- **WHEN** an internal caller attempts to install a local/build trigger without a future expiry
- **THEN** it SHALL be rejected; the adapter SHALL assign the existing lease for legacy events omitting duration before calling the domain.

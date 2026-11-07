## Purpose
The productivity capability provides network-independent countdowns, Pomodoro sessions, scheduled reminders and history with durable deadline semantics, duplicate-safe notification delivery and recoverable migration from SchneeRunner.

## ADDED Requirements

### Requirement: Deadline-based productivity state

The integrated app SHALL preserve deterministic timer, Pomodoro and recurrence logic independent of timer tick delivery, rendering and network availability.

#### Scenario: Mac sleeps past a timer deadline
- **WHEN** the app resumes after the persisted timer deadline
- **THEN** the timer SHALL reconcile from the deadline rather than adding missed timer ticks and SHALL emit its completion at most once.

#### Scenario: Offline productivity
- **WHEN** GitHub is disconnected or unavailable
- **THEN** timers, Pomodoro, reminders and local history SHALL continue to work.

### Requirement: One notification owner per migrated reminder

SchneeBar SHALL use application-owned notification identifiers, reconcile desired schedules from local state and avoid duplicate delivery during coexistence with SchneeRunner.

#### Scenario: Both apps are installed
- **WHEN** a user has not opted into reminder cutover
- **THEN** SchneeBar SHALL NOT silently register a duplicate of an existing SchneeRunner reminder.

#### Scenario: Restart and reconciliation
- **WHEN** the app restarts after an already completed timer
- **THEN** it SHALL NOT repeat the completion notification.

### Requirement: Safe idempotent import

Migration SHALL copy validated legacy data into newly owned storage, record a schema-versioned completion marker and preserve original files unless the user explicitly performs a separate cleanup.

#### Scenario: Migration fails halfway
- **WHEN** a legacy productivity file is unreadable or staging validation fails
- **THEN** no partial target state SHALL become active, legacy files SHALL remain unchanged, and a retry SHALL be available.

#### Scenario: Migration is repeated
- **WHEN** the same source snapshot is migrated again
- **THEN** no duplicate timers, reminder schedules or history entries SHALL be created.

### Requirement: Reminder recurrence is deterministic across clock changes

The app SHALL preserve SchneeRunner's floating-local-time recurrence semantics with the current system calendar/time zone, SHALL recalculate future occurrences when that context changes, and SHALL NOT invent a persisted per-reminder time zone during legacy import.

#### Scenario: Daylight saving time transition
- **WHEN** a weekday or daily reminder crosses a daylight saving time boundary
- **THEN** the next scheduled occurrence SHALL follow a documented calendar policy without duplicate reminders for the same occurrence.

### Requirement: Notification authorization failure does not corrupt productivity state

The app SHALL preserve timers and reminders even when the user denies, withdraws or cannot obtain operating-system notification permission.

#### Scenario: Notification permission denied
- **WHEN** the user denies notification authorization
- **THEN** the app SHALL retain durable timer/reminder data, show a permission-limited state, and SHALL NOT claim a system notification was delivered.

### Requirement: Migration cutover requires explicit confirmation

The app SHALL show which existing Runner data can be imported and SHALL keep **all imported notification-bearing items inactive for the first integration release**. A future cutover SHALL require an independently approved and implemented source-authenticated handoff protocol plus explicit user confirmation; no user-only confirmation can activate migrated notification schedules in the initial release.

#### Scenario: User imports character and timer data without reminder cutover
- **WHEN** import succeeds but the user has not authorized reminder cutover
- **THEN** migrated reminder definitions SHALL remain inactive in SchneeBar and original Runner data SHALL remain unchanged.

### Requirement: Migrated reminders require source-owner acknowledgement

The app SHALL preserve imported reminder/timer/Pomodoro **notification schedules** as inactive in the initial integration release, regardless of source-app version or user acknowledgement. A later separately approved implementation MAY activate only after verified durable evidence that SchneeRunner disabled its own pending requests and future rescheduling; it SHALL not assume another application's pending notifications can be removed.

#### Scenario: Old Runner does not support handoff
- **WHEN** a user imports reminders from a Runner version without a trustworthy stop-and-acknowledge protocol
- **THEN** the imported definitions SHALL remain inactive, the UI SHALL explain data-only import, and the app SHALL NOT schedule migrated reminders.

#### Scenario: Unapproved handoff evidence cannot authorize scheduling
- **WHEN** a source app or user presents a purported stop acknowledgement while no separately reviewed source-authentication protocol is enabled
- **THEN** the migrated notification schedule SHALL remain inactive and no `runnerDisabledVerified` or `barActive` marker SHALL be written.

#### Scenario: Future verified handoff after separate approval
- **WHEN** a later version has an explicitly approved, enabled and verified source peer protocol with fresh source revision, nonce and authenticated source stop proof
- **THEN** SchneeBar MAY activate only its own namespaced migrated notification requests after user consent and durable evidence, and SHALL verify destination ownership before marking cutover complete.

#### Scenario: Source app crashes before acknowledgement
- **WHEN** a cutover is requested but Runner crashes before confirmed disablement
- **THEN** SchneeBar SHALL remain in an awaiting/failed handoff state and SHALL NOT create overlapping reminders.

#### Scenario: SchneeBar crashes during cutover
- **WHEN** the source was disabled but SchneeBar crashes before new schedule activation
- **THEN** restart SHALL reconcile the persisted handoff phase before scheduling and SHALL avoid duplicate notifications or silent source reactivation.

### Requirement: Timezone and daylight-saving compatibility are explicit

The app SHALL follow the existing system-local time scheduling policy for legacy daily/weekday reminders and SHALL apply `Calendar.nextDate` matching policy `nextTime` and repeated time policy `first` unless a separately versioned feature changes this contract.

#### Scenario: Spring daylight-saving gap
- **WHEN** a daily reminder is configured for a local time skipped by the DST spring transition
- **THEN** its next occurrence SHALL follow the calendar's documented nextTime resolution and SHALL not create a duplicate occurrence for that day.

#### Scenario: Autumn repeated clock hour
- **WHEN** the local scheduled hour occurs twice during a DST fall transition
- **THEN** the reminder SHALL use the first matching time and SHALL NOT deliver a duplicate for that calendar occurrence.

#### Scenario: User travels across timezones
- **WHEN** the user's system time zone changes after import
- **THEN** future daily/weekday reminders SHALL use the new system-local clock while one-shot reminders SHALL keep absolute timestamps, and already observed occurrences SHALL not be replayed by the change.

### Requirement: Preference import is separate from file import

The app SHALL inventory and migrate versioned character/productivity preferences from the source app's UserDefaults domain where accessible, SHALL report inaccessible domains, and SHALL avoid claiming a complete migration on partial preference import.

#### Scenario: Source preference domain inaccessible
- **WHEN** the old app's UserDefaults are inaccessible because of bundle or sandbox restrictions
- **THEN** SchneeBar SHALL offer an authorized export/import path or visible omission, SHALL preserve the old app's data, and SHALL NOT silently reset user preferences.

### Requirement: First-release Runner notification import is data-only

In the initial integrated release the application SHALL import supported Runner notification-bearing definitions solely as inactive data, SHALL provide no user-visible or hidden bypass to activate them, and SHALL retain normal notification behavior for new items created in SchneeBar.

#### Scenario: Imported reminder is manually enabled
- **WHEN** a user imports a Runner reminder and attempts to enable delivery without an approved handoff protocol
- **THEN** the app SHALL refuse imported notification scheduling, keep the copied definition visible, and show an explanation that old Runner notifications may still be active.

#### Scenario: Imported timer completion is resumed
- **WHEN** an imported running timer or Pomodoro session is restored on first integration release
- **THEN** its imported completion notification SHALL stay inactive even if its domain countdown is shown, and no duplicate old-app notification SHALL be registered.

#### Scenario: New native reminder is created
- **WHEN** a user creates a brand-new reminder inside SchneeBar rather than importing a Runner schedule
- **THEN** normal SchneeBar-owned notification scheduling SHALL remain available subject to OS authorization and app-local reconciliation.

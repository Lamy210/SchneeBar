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

The app SHALL calculate recurring reminders using the user's configured calendar and time zone rather than depending on a fixed interval since the previous delivery.

#### Scenario: Daylight saving time transition
- **WHEN** a weekday or daily reminder crosses a daylight saving time boundary
- **THEN** the next scheduled occurrence SHALL follow a documented calendar policy without duplicate reminders for the same occurrence.

### Requirement: Notification authorization failure does not corrupt productivity state

The app SHALL preserve timers and reminders even when the user denies, withdraws or cannot obtain operating-system notification permission.

#### Scenario: Notification permission denied
- **WHEN** the user denies notification authorization
- **THEN** the app SHALL retain durable timer/reminder data, show a permission-limited state, and SHALL NOT claim a system notification was delivered.

### Requirement: Migration cutover requires explicit confirmation

The app SHALL show which existing Runner data can be imported and require confirmation before activating migrated notification schedules.

#### Scenario: User imports character and timer data without reminder cutover
- **WHEN** import succeeds but the user has not authorized reminder cutover
- **THEN** migrated reminder definitions SHALL remain inactive in SchneeBar and original Runner data SHALL remain unchanged.

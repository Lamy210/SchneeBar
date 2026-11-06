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

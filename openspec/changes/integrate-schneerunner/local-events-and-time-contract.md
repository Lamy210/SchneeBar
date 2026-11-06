# Contract: Local events, renderer error boundaries and reminder time

Status: Proposed; numerical event budgets are product design thresholds pending real-Mac load profiling, not measurements of the current Runner implementation.

## Untrusted local events

Runner currently accepts DistributedNotificationCenter build/state JSON with channels and per-state TTL rules. Notifications are untrusted; their sender identity is not attested and they cannot authorize a GitHub mutation, import, notification handoff or credential access.

The SchneeBar adapter SHALL enforce before JSON allocation/decoding:
- At most **4,096 UTF-8 bytes** in one raw event (oversized events rejected, not truncated).
- At most **16 accepted events per rolling 1 second** using **12 slots for set/start/update** and **4 reserved slots for clear/cancel**. Nonterminal events MUST NOT consume the terminal reserve. At most **64 concurrently active channels/triggers**. Excess update events are dropped with a bounded, privacy-safe counter; no unbounded queues.
- Any explicit trigger TTL is finite and in **0.1–3,600 seconds**. Events without TTL (including `build.started`) are assigned a **1,800-second lease** and expire unless renewed. A clear/cancel event releases state immediately.
- Validate action, kind, channel length/characters and allowlist **after** the raw byte budget and before state mutation.
- Before the full JSON decoder runs, a constant-work admission counter tracks **at most 128 inbound attempts per rolling 1 second**; overflow clears **all untrusted/local volatile triggers** and quarantines new local events for one second. This makes intentional sender flooding a bounded display-only failure, not a leaked or retained stale state. Importantly, it does **not** clear trusted GitHub metrics, timers, or app settings.
- A valid clear/cancel for an existing local channel is processed using its reserved terminal capacity even when all 12 set/update slots are full. When the 4-slot termination reserve is exhausted, the adapter MUST **fail closed by clearing all untrusted local volatile triggers** and suppressing further untrusted local events until the rolling window resets, not merely drop the requested clear and leave the old state displayed.
- Duplicates coalesce by validated channel/event generation; stale event/session generations and throttled update events do not extend TTL.
- Never interpret string payloads as executable commands or trusted GitHub event origins.

Test 4,096 vs 4,097 bytes; 12 vs 13 updates/sec; four accepted clears despite saturated update slots; fifth clear triggers safe local-state clearing; 128 vs 129 ingress attempts/sec; 64 vs 65 channels; malformed UTF-8; duplicate/stale events; expired build.started; storm quarantine; and all attempts to route local events into GitHub mutations.

## Renderer recovery boundary

A character asset decode error, renderer initialization failure or rejected frame **is recoverable**: disable only Companion playback, show a safe icon/state and preserve menu-bar widgets and Focus. In a single-process app an unhandled fatal process crash cannot preserve the running main UI. On the **next launch** the app may enter safe mode and disable repeatedly failing Companion assets. Any stronger live-crash isolation must be a separately reviewed XPC/helper design, not implied by ADR-0004.

## Recurring reminder calendar policy

For the initial migration, **preserve existing SchneeRunner floating local-time semantics**:
- Runner's `ReminderSchedule` persists daily/weekday `hour` and `minute` (no per-reminder time zone ID) and computes with caller-supplied system Calendar.
- SchneeBar defaults to the **current system calendar and current system time zone at scheduling/reconciliation**. No per-reminder time-zone setting is invented on import.
- For absent local time during DST transition, follow the existing `Calendar.nextDate(matchingPolicy:.nextTime)`; for repeated local time, use `repeatedTimePolicy:.first`. The exact observed result for tested time zones is recorded in the acceptance fixtures.
- On system time-zone change or clock adjustment, recompute future schedules; never blindly shift by 24 hours. Deduplicate observed delivery/completion by stable reminder ID + calendar local occurrence date/rule generation, preventing a second notification for the same intended occurrence across restart or repeated DST hour.
- A new feature for **fixed per-reminder time zone** requires separate schema evolution, UI indication and migration decision; do not claim it exists today.
- One-shot reminders preserve their absolute `Date`, not a floating local clock.

Test UTC/no DST, New York spring gap/fall duplicate, Tokyo/system time-zone change, sleep/restart, manually changed wall clock and user-travel scenarios; document remaining ambiguous cross-zone recurrence semantics rather than guessing.

## Local-event admission ordering and abuse fallback

1. At callback entry, use constant-work aggregate admission accounting to reject an above-budget storm and clear only volatile **local/untrusted** reactions on overflow. The 1-second quarantine bounds decode CPU; the adapter does not preserve unbounded payloads or backlog.
2. Reject raw UTF-8 payload longer than 4,096 bytes before conversion into an allocatable JSON object.
3. Decode a bounded event envelope and enforce allowlisted kind, channel policy and timestamp/generation checks; then apply reserved 12+4 lane budgets.
4. Apply a clear/cancel to a currently active local channel immediately when its 4 reserved slots are available; when exhausted, clear the entire set of volatile local reactions rather than leave an old event active. The per-process accept budget remains at most 16/sec.
5. Never let an untrusted local message cancel a GitHub operation, timer or migration handoff; local-state fail-closed suppression can only alter Companion's voluntary visual reactions.

**Cost/UX trade-off:** deliberate high-rate local spam can suppress nonessential character reactions, which is preferable to stale triggers or unbounded decoding. Numbers are initial test targets, not measured capacity limits; any budget change requires updated versioned fixtures and profiling evidence.

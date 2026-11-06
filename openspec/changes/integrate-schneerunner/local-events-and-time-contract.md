# Contract: Local events, renderer error boundaries and reminder time

Status: Proposed; numerical event budgets are product design thresholds pending real-Mac load profiling, not measurements of the current Runner implementation.

## Untrusted local events

Runner currently accepts DistributedNotificationCenter build/state JSON with channels and per-state TTL rules. Notifications are untrusted; their sender identity is not attested and they cannot authorize a GitHub mutation, import, notification handoff or credential access.

The SchneeBar adapter SHALL enforce before JSON allocation/decoding:
- At most **4,096 UTF-8 bytes** in one raw event (oversized events rejected, not truncated).
- At most **16 accepted local events per rolling 1 second per process**, and at most **64 concurrently active channels/triggers**. Excess is dropped with a bounded, privacy-safe counter; no buffer growth.
- Any explicit trigger TTL is finite and in **0.1–3,600 seconds**. Events without TTL (including `build.started`) are assigned a **1,800-second lease** and expire unless renewed. A clear/cancel event releases state immediately.
- Validate action, kind, channel length/characters and allowlist **after** the raw byte budget and before state mutation.
- Duplicates coalesce by validated channel/event generation; stale event/session generations and throttled events do not extend TTL.
- Never interpret string payloads as executable commands or trusted GitHub event origins.

Test 4,096 vs 4,097 bytes, 16 vs 17 events/s, 64 vs 65 channels, malformed UTF-8, repeated event storms, expired build.started, and all attempts to route local events into GitHub mutations.

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

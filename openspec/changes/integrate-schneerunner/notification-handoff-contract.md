# Contract: Safe reminder ownership handoff between apps

Status: Proposed. **Neither app can assume it can remove the other application's notifications.** The new app is forbidden from automatically activating a migrated reminder merely because the user clicked Import.

## State machine

| State | New SchneeBar scheduled reminders? | Meaning |
| --- | --- | --- |
| `notImported` | No | No migrated definition |
| `copiedInactive` | No | Data imported, no notification ownership |
| `awaitingRunnerStop` | No | User asked for transfer; Runner ownership still unknown |
| `runnerDisabledVerified` | No (staging) | Source app acknowledged it disabled its future schedules and pending owned requests |
| `barActive` | Yes | New app is the one confirmed owner; local notification schedule committed |
| `handoffFailed` | No | Missing/invalid source acknowledgement or target scheduling failure |
| `rollbackPending` | No | New notifications disabled; source re-enable requires separate explicit step |

The **only** route from `awaitingRunnerStop` to `runnerDisabledVerified` is a trustworthy, application-owned acknowledgement from an updated Runner or an equivalently reviewed user-assisted export/disable protocol that includes the source app identity, state revision and durable stop evidence. Raw `DistributedNotificationCenter` messages cannot authenticate this acknowledgement; user clicks alone are not proof that pending system notifications were canceled.

If the installed Runner has no supported stop/ack protocol, offer copy-only data migration with migrated reminders **inactive** and explain the limitation. Do not claim a guaranteed duplicate-free cutover for unsupported old versions. An optional future Runner handoff update is a separate change; the default SchneeBar distribution does not silently reach into another app's notification center.

## Ordering, replay and crash handling

1. Import a snapshot, keep migrated reminder notifications inactive, persist cutover request with source app ID, source revision and idempotency key.
2. Source Runner persistently disables its reminder scheduling on launch, removes **its own** pending identifiers, verifies requested state and emits an authenticated/validated acknowledgement using a designed channel (protocol and trust must be reviewed). A user simply quitting Runner does not imply its pending notifications are gone.
3. On verified acknowledgement, persist `runnerDisabledVerified`, then schedule new app notifications with new namespace and read back new pending identifiers. Store the `barActive` marker only after verifying destination ownership.
4. If new scheduling fails, do not silently re-enable Runner, and do not present the handoff as complete. Surface `handoffFailed` with retry or explicit rollback guidance.
5. On restart, reconcile persisted handoff state before all notification scheduling. Cancel/ignore late/stale acknowledgements; reactivation of old Runner is a distinct user-controlled action after `barActive` has ended.
6. Use only the actual app's namespaced `UNUserNotificationCenter` identifiers; never cancel arbitrary third-party pending notifications. Signed/unsigned runtime limitations are tested separately.

## Acceptance

- Both apps installed and source version lacks stop protocol → new migrated reminders remain inactive.
- Verified Runner disable+ack, then Bar schedule → exactly one owner; old Runner relaunch does not re-schedule while transfer state is durable.
- Source process crash before disabling pending requests → no acknowledgement, no Bar scheduling.
- Bar crashes after old disable but before Bar schedule → restart resumes staging without duplicate notifications.
- No target authorization → migrated state stays durable, no claimed notification delivery.
- Rollback from active Bar → only Bar-owned notifications removed; Runner never silently reactivated.

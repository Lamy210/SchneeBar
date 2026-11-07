# Contract: Safe reminder ownership handoff between apps

Status: Proposed. **Initial SchneeBar integration implementation is data-only for imported notification-bearing items**; no production SchneeRunner stop/acknowledge channel exists or is approved in this change. Neither app can assume that it can remove the other application's notifications.

## Explicit release scope and fail-closed decision

- For the **first integration release**, `runnerReminderHandoffEnabled` is an internal, non-user-toggleable **false** capability. All imported Runner reminder schedules, pending timer-completion notifications, and imported Pomodoro notification schedules remain **inactive** in SchneeBar. The user can inspect/edit the imported definitions, but activating a migrated one via UI, restart, import retry or hidden settings SHALL fail closed with an explanation.
- This restriction **does not disable new timers/reminders created directly inside SchneeBar** or unrelated local notifications owned by SchneeBar.
- It is not sufficient to quit, uninstall or force-quit Runner, click “I stopped Runner”, or see an unauthenticated `DistributedNotificationCenter` event. Old pending `UNUserNotificationCenter` requests can still exist.
- Any transition beyond `copiedInactive` for **imported notifications** requires a **separate approved and deployed handoff protocol change**, a version-compatible Runner binary, both sides' acceptance tests and the user's explicit consent. UI MUST NOT expose an unsafe override. A signed/unsigned preview with no validated trust channel remains data-only.
- A future protocol is **not implicitly approved** by this spec. Until implemented, the state names below describe a gated future capability, not a working runtime.

## Current-release state machine

| State | New SchneeBar migrated notifications? | Meaning |
| --- | --- | --- |
| `notImported` | No | No migrated definition |
| `copiedInactive` | No | Data imported and visible, but notification ownership never changes |
| `handoffUnavailable` | No | User requests activation but source attestation capability is unsupported, unknown or unconfigured |

Valid initial transitions: `notImported → copiedInactive`; `copiedInactive → handoffUnavailable → copiedInactive` after a user acknowledges the limitation. App restart and migration retry keep all migrated notification schedules inactive. This initial version SHALL NOT persist `runnerDisabledVerified` or `barActive`.

## Reserved future state machine (separate reviewed feature)

| State | Bar migrated notifications? | Required evidence |
| --- | --- | --- |
| `awaitingRunnerStop` | No | Explicit transfer intent and source revision |
| `runnerDisabledVerified` | No (staging) | Cryptographically or OS-identity authenticated, replay-resistant source stop proof |
| `barActive` | Yes | Confirmed source stop plus verified Bar-owned pending requests |
| `handoffFailed` | No | Missing/invalid ACK, authorization, or target schedule |
| `rollbackPending` | No | Bar-owned requests suspended; re-enabling Runner requires a separate explicit action |

The only route from `awaitingRunnerStop` to `runnerDisabledVerified` in a future implementation is an approved trust channel that proves source Runner identity and durable revocation of its future scheduling **and its own pending notifications**. The new protocol MUST name: transport and authenticated peer identity (e.g. code-signing + peer audit identity where technically supported, not a display name), eligible signing teams/Runner versions, direction and exact object types, one-use nonce or challenge, source revision, per-transfer idempotency key, expiry, replay rejection, revocation/cancellation semantics, durable staging/ack ordering and crash-recovery evidence. **No protocol or secret is inferred from current Runner's unsigned app or DistributedNotificationCenter.**

If a compatible signed/trusted protocol cannot be implemented, source cutover is rejected and the data-only behavior remains the supported product contract. Manual confirmation alone NEVER constitutes a verified ACK.

## Future ordering, replay and crash requirements (not active in initial release)

1. Import a snapshot without scheduling imported notifications. Persist source revision, transfer intent and idempotency key.
2. Verified source Runner must durably disable *its own* scheduler on next launch, remove its pending notification identifiers and provide signed/authenticated revision-bound stop evidence. A simple notification payload or the user's click is not sufficient.
3. Only after validated source stop evidence may Bar schedule its own namespaced requests; read back destination pending identifiers and persist `barActive` after verifying destination ownership.
4. If destination scheduling fails or the ACK is stale/untrusted, remain inactive; never silently re-enable the old source.
5. After crash/restart reconcile the persisted handoff phase before scheduling. Any source restart must preserve transferred-away state or the transfer MUST fail closed.
6. On rollback, remove only Bar-owned requests; source re-enable is a separate explicit action with validated order. Do not access another app's notification center.

## Acceptance

- First integration build, any Runner version including unsigned legacy → imported reminder/timer/Pomodoro schedules stay inactive after import, restart, duplicate import and user attempts to activate.
- New Bar-created reminder or timer → normal user-authorized Bar notification behavior is unaffected by the imported-schedule gate.
- Fake source ACK via DistributedNotificationCenter, modified export or user “I stopped it” checkbox → no imported notification activation.
- Old Runner's pending reminders continue to belong to Runner; Bar never asserts they were canceled.
- Future approved protocol is tested with spoofed peer, wrong signer, stale revision, nonce replay, two-app restart, crash before ACK, Bar crash between ACK and registration, and notification-permission denial before strict activation can be enabled.

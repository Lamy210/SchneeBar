# C1a implementation contract: trigger arbitration

Status: Proposed, pending ADR-0004 approval; independent implementation draft only, not a release or adoption decision.

Split C1 into C1a (state arbitration), C1b (animation timing/clip identity), C1c (EMA/CPU adaptation). No source or test-file copying is authorized by this document. A fresh implementation of observable behavior may be reviewed in a separate inactive draft while source reuse and ADR acceptance remain pending; do not merge or link to production until gates pass.

## C1a observable API and invariants

- Internal source key is a typed value: singleton manual, CPU, local build and productivity, or UUID-scoped local state, system advisory, system event and developer. UUIDs are normalized by future adapters; no untrusted payload is passed to this target. Adapter must retain stable mapping for the lifetime of one active identity, with bounded storage.
- Priority is derived from source, never passed as a caller-controlled integer; newest successfully accepted change breaks ties. Default state run. Clearing manual returns to Automatic while other triggers remain. State is separate from playback rate.
- Inject elapsed monotonic Duration from one shared runtime origin. Accepted observations are nonnegative and nondecreasing; reject backwards observation without modifying state. A deadline equal to now is expired. Renewal replaces its previous deadline; a wakeup only reconciles the current set, not an obsolete captured clear closure. No scheduling or clock read in the domain; caller schedules earliest current expiration and reconciles on resume. CPU invalidation explicitly clears CPU. Manual state has no expiry.
- Proposed resource limits: max 128 total entries, including reserved singleton manual and CPU slots; at most 126 other entries and 64 combined local-state/build entries. Reject new identities when full, allow updates to existing identities, no eviction of unrelated state. Limits are defensive draft parameters, not an assertion of original Runner behavior. Existing raw admission/quarantine limits in local-events-and-time-contract.md remain mandatory in the future adapter; local/build keys require future deadlines (and adapter applies TTL limits/default lease). Do not classify device, productivity or GitHub provenance from external strings.
- No AppKit, SwiftUI, Keychain, network, files, timers, image resources or production app dependency in C1a. Test target uses Swift Testing. No new required CI workflow; existing Tuist build/test must include the new target.
- C1b/C1c remain separate: authored frame duration ratios, unchanged-clip continuity, EMA/hysteresis against source fixtures. Do not claim C1 parity on C1a completion.

## C1a acceptance matrix

| ID | Input | Expected |
| --- | --- | --- |
| A01 | empty set; metric, advisory, system event, event, manual | run fallback; priorities 100/300/400/500/1000 |
| A02 | two event identities and renewed older identity at same tick | newest accepted wins; clearing reveals surviving trigger |
| A03 | local deadline 10s, renew at 5s to 20s, resolve 10s then 20s | survives old deadline; expires at new deadline |
| A04 | advance to 20s then try 19s | rejection, no resurrection or mutation |
| A05 | full combined local/build cap; fill remaining nonreserved slots | rejects excess, manual/CPU reserved, update and clear remain possible |
| A06 | manual expiry, local no expiry, past/equal deadline | reject invalid installs; prior valid trigger remains |
| A07 | clear only local/build class after storm | no change to manual, CPU, system or productivity/developer |
| A08 | source-independent build/test | no privileged target imports, no app integration; Linux isolated Swift test possible, macOS Tuist validation still required |

The full integration task 9.2 and issue #370 stay open until remaining C1b/C1c and original acceptance are evidenced. No original tests copied; source fixture comparisons and license/ADR decision still required.

## Review correction: explicit observation at clear and rejection semantics

Clear and local quarantine take the same monotonic elapsed timestamp as submit/advance; reconcile expired entries before removing requested identities. Reject time regression with no change. State/nextDeadline getters reflect the last reconciled time, not a live clock. A rejected insert at a valid later timestamp may still expire unrelated elapsed entries; it must not replace or evict any live entry. The Core also rejects local/build deadlines more than 3600 seconds after acceptance; a positive shorter remaining duration is allowed after adapter-side wire validation of the 0.1-second minimum. An asynchronous callback must be generation-fenced by its adapter; scheduled expiry uses advance, never an unversioned clear. A delayed raw legacy v1 event does not have authenticated sender generation and cannot be proven fresh; do not promise that. The typed timestamp is local observation time, not proof of sender ordering.

Additional fixtures: clear manual at the underlying event deadline resolves fallback; regressed clear/quarantine leaves state untouched; rejected later insert expires elapsed entries without evicting live ones; local 3600s accepted, >3600s rejected. Existing C1a draft is updated before further integration.

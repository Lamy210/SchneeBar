# PR-D1: bounded local Runner v1 event admission (independent draft)

Scope: synchronous data-to-domain adapter only. Runner baseline c925816d4f7ec4e07a5c6db74fd6038fea3aa71d, observable wire inputs from Sources/SchneeRunnerCore/LocalBuildEvent.swift and LocalCharacterStateEvent.swift. No source/test/assets copied from Runner. The new adapter depends only on CompanionCore and Foundation/CoreFoundation; no AppKit, notification observer, CLI executable, GitHub, network or credential operations. Neither shipping app nor preview links this target yet. Depends on the existing local-events-and-time-contract.md and ADR-0004 gates.

- Admit the two exact v1 notification kinds via typed entry. Raw received Data <=4096 bytes, valid UTF-8, no embedded NUL; reject unknown object keys, invalid enum/field types, invalid channel scalars or channel >64 UTF-8 bytes, booleans as TTL, and clear with non-null state/TTL. Missing or null channel defaults to default. Missing TTL becomes a 1800s lease. Unknown keys intentionally rejected (stricter than legacy Codable). JSONSerialization does not guarantee rejection of duplicate keys; this is a display-only adapter, not a signature or authentication parser.
- Fixed bounded rolling windows: 128 raw attempts, 12 update/start admissions, 4 terminal admissions per second. Capacity-refused valid events consume their lane conservatively. The 129th raw attempt or fifth terminal clears ONLY local sources and quarantines ingress for a full second. Quarantined calls perform no decode/arbitration scan. No payload backlog; invalid data counts at entry. This only bounds application decoding/admission after transport delivers Data, not allocations made by the operating system.
- Build singleton: started = dash/1800s, succeeded = sprint/2s, failed = idle/5s, cancelled = clear. Character channel and build share 64 active entries; assign stable typed UUID per live channel, prune expired mappings, renew only admitted events. Never evict a trusted source; no authority to interpret a command.
- Monotonic elapsed duration is supplied by one serialized owner. The owner must call advance at the earliest current arbitration deadline and after wake, and be the exclusive writer of local sources. v1 has no sender nonce/generation/timestamp: repeated valid wire set/start is a new observation/renewal once admitted, not an authenticated unique event. Stale local clock rejects; future listener must generation-fence its own queued callbacks. A full second of quarantine is intentionally more conservative than earliest rolling-lane reopening.
- Local tests use independent fixtures; exact arbitration blob fab51572af31e3c9ce837addf44e589cb0e1d288, Swift 6.2.1 Linux 7 tests passed. Native macOS/Tuist validation, actual notification transport and deadline scheduling, measured ingress performance, disable/unsubscribe behavior and no-privilege integration tests remain necessary. Do not mark broader tasks 3.4, 7.6, 8.3 or 9.5 completed or enable any listener. Keep the existing preview PR #393 unchanged while its CI is pending.

## Acceptance

| Fixture | Expected |
| --- | --- |
| 4096/4097 bytes, malformed UTF-8 | accept bounded valid input; reject oversize/malformed |
| unexpected command key, invalid state/channel/TTL/type | reject; no trigger |
| four build phases | bounded effects and expiry/clear |
| twelve updates, four clears, fifth clear | terminal reserve; clear local only, preserve manual and CPU, quarantine |
| 128/129 raw attempts | fail closed even if input malformed |
| combined 64/65 entries | reject excess; renew existing; recover on expiry |
| dropped update, time regression, renewal | no lease extension from rejected update, no resurrection, stable live identity |

Next: test Darwin Foundation parsing/notification wrapper, bounded callback admission before any String-to-Data conversion, lifecycle generation, expiration wakeup and preview opt-in with real-Mac measurements. No production activation or additional release.

# C1b/C1c playback and adaptive-policy contract

Status: proposed, isolated draft implementation only. ADR-0004, source reuse rights, macOS integration and user activation remain gated. Reference behavior: Runner c925816d4f7ec4e07a5c6db74fd6038fea3aa71d, AnimationSchedule, CharacterAnimationLibrary, AnimationController, AdaptiveAnimationSpeedPolicy, CPUMonitor and StatusMenuController. No Runner source/test/assets copied.

## Playback (C1b)
- A clip has an opaque revision identity, bounded ordered base-frame durations, and no image/process references. A catalog must have a defined default clip. Map requested states to an exact clip or the default. A repeated selection resolving to the same clip revision and timing must not reset the frame index or invalidate a pending tick. A changed clip revision/timing resets to frame 0, invalidating pending ticks. Adapter must mint a new revision when asset content changes; same revision with conflicting timing in one catalog is invalid.
- Proposed timing policy: 1 through 120 frames and each finite base duration in 0.02...10 seconds (matches default animated loader duration range; also supports the default procedural and sprite duration; verify all pack/sequence loader paths before adoption). Reject, not clamp, invalid schedules at this boundary. The asset adapter must independently bound bytes, image dimensions, cumulative decoded pixels and preallocation. No image decoding here. Uniform schedules use 12 FPS unless an explicit supported schedule is provided.
- Display labels 0.5x / 0.67x / 1x / 1.5x / 2x correspond to actual factors 6/12, 8/12, 12/12, 18/12, 24/12. Duration is base divided by factor; do not round away authored ratios. Playback rate is separate from character state. A rate change retains the current frame, invalidates the old tick and requests the new full current-frame duration (as Runner does). Same rate is a no-op.
- Cursor returns a frame index and at most one next-tick token/delay. A single frame has no timer. Accept a tick only if it matches the current cursor token; accept once and advance one frame modulo count, never catch up by unbounded looping. On clear or replacement invalidate old tokens; on hide the renderer adapter must cancel its timers and clear that cursor or use a separately reviewed suspend/resume API. Tokens are scoped to one cursor lifetime, never shared between renderers; no callback may be routed to a replacement cursor. No wall-clock or timer ownership in this pure module.

## CPU adaptation (C1c)
- Input is a finite host-wide percentage in 0...100, not per-process CPU and not a 0...1 fraction; normalize once. Invalid/missing input resets derived state and returns unavailable (intentional hardening vs Runner policy's finite out-of-range clamp). No pretending that unavailable equals 0%.
- On first sample EMA equals normalized observation; subsequent alpha 0.25; start pace idle; thresholds [0.15, 0.40, 0.70, 0.90] with hysteresis 0.03. Increase when >= threshold+hysteresis, decrease when < threshold-hysteresis; multiple steps allowed. State/pace mapped to the five fixed rates above. Explicit reset clears EMA and pace. At runtime adapter clears CPU trigger on invalidation and uses normal rate when automatic has no valid sample.
- Runner sampled nominally once per second; Bar nominally every five seconds. Identical per-observation EMA is NOT identical elapsed-time response. Initial shared 5s cadence is an intentional experimental difference; do not introduce second sampler. Evaluate a time-normalized EMA (alpha(dt)=1-(1-0.25)^dtSeconds) or a different shared cadence in PR-B using measured latency/wakeups; no automatic change here. Only apply EMA once per distinct valid sample; stale/duplicate sample generation rejected at the future shared service boundary, not in this pure policy.
- Manual playback rate and manual state override are independent. Switching to manual speed disables automatic CPU state/rate contribution; user chooses manual rate without changing state override; reenabling automatic restores policy ownership. Actual composition, reset/re-enable semantics and generation invalidation remain PR-B/app adapter tasks, not implemented in C1c.

## Acceptance
| ID | Input | Expected |
| --- | --- | --- |
| B01 | 1, 120, 0, 121 frames; NaN, infinity, zero, <0.02, >10 durations | valid bounds accepted; invalid rejected |
| B02 | authored 0.04/0.12/0.08 and all five rates | scaled duration ratios preserved, 8/12 exact |
| B03 | default-only catalog, exact and missing states, missing default, conflicting revision | deterministic fallback; invalid catalogs rejected |
| B04 | tick, repeat same clip, rate change, old tick | continuity on same clip; rate change retains index and invalidates old tick |
| B05 | replacement revision, clear, one frame, duplicate callback | old tokens rejected, no timer for single/empty, one accepted tick advances at most one frame |
| C01 | first 50%, next 0% | normalized EMA 0.5 then 0.375, accurate rate/state |
| C02 | independent fresh 95%; 50/39/36% hysteresis with smoothing tested separately | multi-band jump to sprint; raw pace policy stays run at 39%, walk at 36% |
| C03 | NaN/+infinity/-1/101/missing; reset then valid | unavailable, no stale EMA, next valid sample reseeds |
| C04 | manual speed vs CPU state and distinct sampler generations | runtime adapter follow-up; do not mark complete from policy unit tests |

Real-Mac profile, original full fixture ledger, exact artifact revision wiring, timer/clock lifecycle, code/asset rights and ADR acceptance remain pending.

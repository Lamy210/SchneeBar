# Shared host CPU sampler rollout (PR-B1)

Status: proposed implementation draft; runtime composition and Companion connection are separate PR-B2. Issue #365. Reference: Bar ce6478f7 existing CPUWidgetProvider and SystemWidgetProviderTests; Runner c925816d CPUMonitor.

## Ownership and cadence

One actor owns the host counter baseline, monotonic sampling window and in-flight acquisition. Demand-driven: no standalone polling task. Each of the two typed consumers (widget/companion) obtains an idempotent lease; stale lease removal cannot revoke a newer lease. First acquisition uses the existing 500ms bootstrap pair. The cached observation (including failure) is shared for less than five seconds from completion; exactly five seconds permits the next acquisition. Cached valid samples retain original ID, epoch, monotonic timestamp and wall-clock timestamp. Widget display uses raw percentage, existing descriptor/labels and severity. Companion must apply EMA once per unique valid sample ID, not every cached read. The existing 30-second maximum counter interval and modulo arithmetic remain. Long gaps bootstrap; sleep/wake must explicitly invalidate even shorter gaps. Distinguish errors from true 0%; valid counter stall/reset behavior retained. No extra autonomous loop; app composition will schedule acquisition through a single lifecycle owner.

## Lifecycle

Final lease removal or explicit suspend invalidates the epoch, cancels and detaches the current flight, and clears baseline/cache. Resume does not revive old observations. An obsolete task must check the epoch after a suspended bootstrap, and a waiter can only finalize its own flight. Individual waiter cancellation must not stop a different active consumer. Return cancellation for stale lease/epoch. The current synchronous Mach read cannot be interrupted mid-call; no claim of hard real-time cancellation.

B1 extracts sampling and connects the existing standalone widget provider via its default widget lease; adds an injection initializer so both consumers can share the same actor. App composition currently still uses the default initializer: user toggle/sleep lifecycle does NOT yet explicitly drive leases. No Companion production subscription, timer, or auth integration yet. B2 must create one shared instance, serialize configuration transitions, wire sleep/wake and final unsubscribe, fence stale UI and use distinct sample IDs for EMA. B1 alone does not satisfy completed tasks 3.2/3.3/9.3 or issue #365. Keep feature inactive until those gates pass. This draft retains the original 5s widget descriptor; caching within 5s intentionally avoids redundant reads, and cached errors share that budget. Measure performance and time response before adoption.

## Verification

Existing CPU widget deterministic tests remain; new cases cover cross-consumer shared sample + exact window boundary, stale bootstrap after unsubscribe/resubscribe, short sleep with active companion and expired/stale leases, shared failure/recovery. Real-Mac aligned Activity Monitor validation, app-level configuration races, CPU-only/Companion-only and both-enabled lifecycle tests and actual performance still outstanding.

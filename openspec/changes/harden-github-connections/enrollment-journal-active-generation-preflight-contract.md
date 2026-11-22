# P0: fail-closed active-generation preflight for V2 enrollment

## Gap
The V2 enrollment journal offers `record(for:)` (cached), and `refreshRecord(for:)` (durably reloaded). A future credential owner must not accidentally treat a generic loaded record, or a caller-supplied `dpActive` snapshot, as authorization to access V2 Keychain. It must compare the current durable generation against the generation that initiated the credential operation and confirm that the current phase remains `dpActive`.

## Read-only policy
- Introduce `requireFreshActiveRecord(for:expectedGeneration:)` on the journal actor.
- Every invocation re-reads and validates the full durable journal using the existing persistence adapter. Its file adapter takes the shared cross-process lock while reading; any failed or corrupt read clears stale cached state.
- If the record is missing: `missingEnrollment`. If its generation differs from the expected generation: `staleSnapshot`. If the generation matches but its phase is not `dpActive` or generation is too small: `inactiveEnrollment`. No Keychain or network I/O is allowed.
- Valid results contain only a structurally validated `dpActive` enrollment with the matching expected generation. Keep `record(for:)`, `refreshRecord(for:)`, existing journal CAS write rules, V2 Keychain policies and legacy sessions unchanged.
- Always recheck before using the credential. Do **not** use `requireFreshActiveRecord` as a substitute for the needed cross-process transaction fence across Keychain reads and provider API calls: a disconnect can race immediately after return.

## Deterministic regressions
- Memory adapter: prepared/refresh-in-flight and unexpected generation rejected; legitimate dpActive generation accepted; unknown enrollment rejected.
- Two journal actors: one caches a live generation while another persists a disconnected state; the guard rejects both the stale expected generation and current disconnected generation.
- Memory I/O injection and duplicate/corrupt records fail closed instead of authorizing a cached active snapshot.
- Private-directory real-file adapter: separate journal actors, generation 2 accepted before disconnect, rejected as stale after disconnect, generation 3 rejected as inactive.

## Gates and limits
- macOS CI Build/Test must execute the four new Swift Testing tests, Visual Regression, OpenSpec strict; zero unresolved review threads before any main merge.
- Opt-in research-only API, **not wired to shipping authorization**. No claims of verified live GitHub identity, durable lease, actual signed-Keychain behavior, secret lifecycle/refresh/rollback or cross-process operation fencing. Issue #368 stays open.

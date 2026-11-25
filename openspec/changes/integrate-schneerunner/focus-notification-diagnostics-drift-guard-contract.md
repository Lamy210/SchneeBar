# E3z: fail-closed durable drift guard for notification diagnostics

## Motivation
E3y reads a Focus Outbox snapshot, suspends to obtain two non-atomic macOS notification lists, and returns a count-only inspection. During these asynchronous OS calls, a separate owner may ACK, rename, disable, remove or otherwise change the durable collection. An old diagnostic should never be presented as though it reflects the latest local state, especially when it would be used for operational troubleshooting.

## Contract
- `FocusReminderNotificationDiagnosticsReader.load(maximumEvidenceCount:)` must load a validated durable snapshot, obtain existing bounded read-only OS evidence, **re-load the durable snapshot**, and require strict complete equality of the before/after snapshots before returning a diagnostics projection.
- If the snapshot changed, reject with the explicit `FocusReminderNotificationDiagnosticsError.durableSnapshotChanged` (Equatable/Sendable). This includes ACK/Outbox changes and title or metadata changes, even when an aggregate happens to have the same count. Never return an earlier partial summary as current.
- This is a conservative **single-pass consistency guard** only. It is not a cross-process lock, a transaction spanning UserNotifications and the file, or proof of no ABA or post-return changes. Do not claim OS delivery, permit resend/ACK/remove/cancel, or attempt automatic retries. A caller may explicitly retry a fresh read after showing a neutral stale-state warning.
- Continue preserving the distinction between absent OS evidence (ambiguous), untracked OS-owned identifiers (potentially previously ACKed), other namespaces and authorization restrictions.
- No changes to the notification gateway API, storage encoding, private title logging, permission prompts, actual OS notifications, shipped app composition, runner lifecycle, signing, distribution or PR #396 main promotion.

## Verification
- Deterministic injected notification center that ACKs an Outbox record mid-inspection causes an explicit drift error and **no diagnostic result**; a fresh retry sees zero Outbox intents plus the untracked OS-owned identifier, without submission or removal.
- The same center renames a reminder mid-inspection: even if Outbox counts are unchanged, the first inspection must fail closed; a fresh read succeeds with the renamed metadata and unchanged Outbox.
- Stable Outbox during OS evidence inspection returns accurate counts without changing file bytes or invoking add/remove.
- Existing E3y seven diagnostics tests must remain green, with native macOS Build/Test, Visual Regression, strict OpenSpec, latest branch comparison and zero unresolved reviews. CodeQL skipped is not PASS; Ready state can trigger its configured analysis.
- This change depends on PR #490. Do not merge into integration until #490 has passed its required checks and merged, then retarget to latest integration and validate the exact patch and HEAD.

import Foundation
import SchneeBarFocusPersistence

/// One read-only view combining durable Outbox pressure and OS evidence.
/// No user content, IDs, or actionable requests are returned.
public struct FocusReminderRecoveryUnifiedTriageReport: Equatable, Sendable {
    public let observationDate: Date
    public let preview: FocusReminderAcceptedRequestRecoveryPreview
    public let backlog: FocusReminderOutboxBacklogDiagnostics
}

/// Operator-facing observation boundary, not a transport, dispatcher or
/// recovery authorizer. The future UI must call an explicit recovery command
/// which revalidates OS proof and the current durable Outbox.
public actor FocusReminderRecoveryUnifiedTriage {
    private let store: FocusReminderCollectionStore
    private let gateway: FocusReminderNotificationGateway

    public init(store: FocusReminderCollectionStore, gateway: FocusReminderNotificationGateway) {
        self.store = store
        self.gateway = gateway
    }

    /// Always uses ONE validated durable snapshot for both sets of counts.
    /// OS pending/delivered queries are separate and non-atomic; they can
    /// change after this call. No add/remove, permission prompt or ACK.
    ///
    /// Invalid date/age parameters fail before any OS observation.
    public func inspectOnce(
        at now: Date,
        agedAfter: TimeInterval,
        maximumEvidenceCount: Int = 2_048
    ) async throws -> FocusReminderRecoveryUnifiedTriageReport {
        let snapshot = try await store.load()
        let backlog = try snapshot.outboxBacklogDiagnostics(
            at: now, agedAfter: agedAfter
        )
        let inspection = try await gateway.inspect(
            snapshot, maximumEvidenceCount: maximumEvidenceCount
        )
        let authorization = inspection.evidence.authorization
        let allowed = authorization == .authorized || authorization == .provisional
        let plan = inspection.plan
        let preview = FocusReminderAcceptedRequestRecoveryPreview(
            authorization: authorization,
            queuedOutboxCount: snapshot.outbox.count,
            observedInSystemCount: plan.observedInSystem.count,
            candidateAcknowledgementCount: allowed ? plan.observedInSystem.count : 0,
            needsManualRecoveryCount: allowed ? plan.missingSystemEvidence.count
                : snapshot.outbox.count,
            untrackedOwnedIdentifierCount: plan.untrackedOwnedIdentifiers.count,
            ignoredIdentifierCount: plan.ignoredIdentifierCount
        )
        return FocusReminderRecoveryUnifiedTriageReport(
            observationDate: now,
            preview: preview,
            backlog: backlog
        )
    }
}

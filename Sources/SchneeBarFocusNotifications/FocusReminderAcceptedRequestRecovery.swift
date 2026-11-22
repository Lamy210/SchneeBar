import Foundation
import SchneeBarFocusPersistence

/// Developer-facing, single-pass recovery result. No user notification
/// delivery or presentation is implied by an OS request acknowledgement.
public struct FocusReminderAcceptedRequestRecoveryReport: Equatable, Sendable {
    public let authorization: FocusReminderNotificationAuthorization
    public let acknowledgedCount: Int
    public let needsManualRecoveryCount: Int
    public let untrackedOwnedIdentifierCount: Int
    public let ignoredIdentifierCount: Int

    public var permissionAllowsEvidence: Bool {
        authorization == .authorized || authorization == .provisional
    }
}

/// Read-only operator snapshot. Counts describe an OS observation at one point
/// in time, not permission to send/ACK or evidence of user-visible delivery.
/// Preview never mutates the durable Outbox or the OS notification center.
public struct FocusReminderAcceptedRequestRecoveryPreview: Equatable, Sendable {
    public let authorization: FocusReminderNotificationAuthorization
    public let queuedOutboxCount: Int
    public let observedInSystemCount: Int
    public let candidateAcknowledgementCount: Int
    public let needsManualRecoveryCount: Int
    public let untrackedOwnedIdentifierCount: Int
    public let ignoredIdentifierCount: Int

    public var permissionAllowsEvidence: Bool {
        authorization == .authorized || authorization == .provisional
    }
}

/// Explicitly invoked only: the shipping app is not wired to this actor.
/// Reconciles an OS-visible request that survived an earlier acceptance/ACK
/// crash. Unobserved requests remain queued and are never resubmitted here.
public actor FocusReminderAcceptedRequestRecovery {
    private let store: FocusReminderCollectionStore
    private let gateway: FocusReminderNotificationGateway

    public init(store: FocusReminderCollectionStore, gateway: FocusReminderNotificationGateway) {
        self.store = store
        self.gateway = gateway
    }

    /// Read-only triage for a future explicit recovery UI. It is not a
    /// pre-authorization for recoverOnce(): OS evidence and Outbox state may
    /// change immediately after this call, so recovery must inspect again.
    /// No OS add/remove/prompt, durable ACK, or private identifier disclosure.
    public func previewOnce(
        maximumEvidenceCount: Int = 2_048
    ) async throws -> FocusReminderAcceptedRequestRecoveryPreview {
        let snapshot = try await store.load()
        let inspection = try await gateway.inspect(
            snapshot, maximumEvidenceCount: maximumEvidenceCount
        )
        let authorization = inspection.evidence.authorization
        let allowed = authorization == .authorized || authorization == .provisional
        let plan = inspection.plan
        return FocusReminderAcceptedRequestRecoveryPreview(
            authorization: authorization,
            queuedOutboxCount: snapshot.outbox.count,
            observedInSystemCount: plan.observedInSystem.count,
            candidateAcknowledgementCount: allowed ? plan.observedInSystem.count : 0,
            needsManualRecoveryCount: allowed ? plan.missingSystemEvidence.count
                : snapshot.outbox.count,
            untrackedOwnedIdentifierCount: plan.untrackedOwnedIdentifiers.count,
            ignoredIdentifierCount: plan.ignoredIdentifierCount
        )
    }

    /// No OS add/remove/prompt. Returns only after the durable acceptance
    /// records were atomically acknowledged, or throws with no partial ACK.
    /// A concurrent disable, delete or rule change invalidates the complete
    /// batch via the store's exact-record compare-and-swap validation.
    public func recoverOnce(
        maximumEvidenceCount: Int = 2_048
    ) async throws -> FocusReminderAcceptedRequestRecoveryReport {
        let snapshot = try await store.load()
        let inspection = try await gateway.inspect(
            snapshot, maximumEvidenceCount: maximumEvidenceCount
        )
        let authorization = inspection.evidence.authorization
        let plan = inspection.plan
        let allowed = authorization == .authorized || authorization == .provisional
        if allowed && !plan.observedInSystem.isEmpty {
            _ = try await store.acknowledgeObserved(records: plan.observedInSystem)
        }

        return FocusReminderAcceptedRequestRecoveryReport(
            authorization: authorization,
            acknowledgedCount: allowed ? plan.observedInSystem.count : 0,
            needsManualRecoveryCount: allowed ? plan.missingSystemEvidence.count
                : snapshot.outbox.count,
            untrackedOwnedIdentifierCount: plan.untrackedOwnedIdentifiers.count,
            ignoredIdentifierCount: plan.ignoredIdentifierCount
        )
    }
}

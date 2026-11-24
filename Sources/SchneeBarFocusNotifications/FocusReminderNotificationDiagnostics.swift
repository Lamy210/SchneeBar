import Foundation
import SchneeBarFocusPersistence

/// A bounded, privacy-preserving diagnostic projection, NOT a decision to
/// acknowledge, resend or remove any notification.
public struct FocusReminderNotificationDiagnostics: Equatable, Sendable {
    public enum EvidenceQuality: Equatable, Sendable {
        /// Authorization is denied/unknown: absence of OS evidence is
        /// especially inconclusive and must never trigger a retry.
        case authorizationRestricted
        /// Two independently captured OS lists are not an atomic receipt:
        /// observed identifiers are not proof of user presentation.
        case nonAtomicSnapshot
    }

    public let authorization: FocusReminderNotificationAuthorization
    public let evidenceQuality: EvidenceQuality
    /// An Outbox record whose namespaced identifier appeared in OS evidence.
    /// This is not durable ACK or proof that a user saw the notification.
    public let observedOutboxCount: Int
    /// A durable Outbox record not found in either OS list.
    /// It may already have been delivered or dismissed.
    public let missingSystemEvidenceCount: Int
    /// An OS-owned identifier not currently in the Outbox; it might have
    /// been acknowledged already, so it must not be removed automatically.
    public let untrackedOwnedIdentifierCount: Int
    /// IDs outside the exact canonical SchneeBar Focus namespace.
    public let ignoredIdentifierCount: Int

    public var durableOutboxCount: Int {
        observedOutboxCount + missingSystemEvidenceCount
    }

    public var requiresManualReview: Bool {
        evidenceQuality == .authorizationRestricted
            || missingSystemEvidenceCount > 0
            || untrackedOwnedIdentifierCount > 0
    }

    public init(inspection: FocusReminderNotificationInspection) {
        let evidence = inspection.evidence
        let plan = inspection.plan
        authorization = evidence.authorization
        evidenceQuality = switch evidence.authorization {
        case .authorized, .provisional: .nonAtomicSnapshot
        case .notDetermined, .denied, .unsupported: .authorizationRestricted
        }
        observedOutboxCount = plan.observedInSystem.count
        missingSystemEvidenceCount = plan.missingSystemEvidence.count
        untrackedOwnedIdentifierCount = plan.untrackedOwnedIdentifiers.count
        ignoredIdentifierCount = plan.ignoredIdentifierCount
    }
}

/// Read-only owner for developer diagnostics. The local Outbox snapshot and
/// two macOS evidence lists are NOT a transaction. Results can go stale even
/// before this method returns; they MUST NOT authorize any state mutation.
public actor FocusReminderNotificationDiagnosticsReader {
    private let store: FocusReminderCollectionStore
    private let gateway: FocusReminderNotificationGateway

    public init(store: FocusReminderCollectionStore, gateway: FocusReminderNotificationGateway) {
        self.store = store
        self.gateway = gateway
    }

    public func load(maximumEvidenceCount: Int = 2_048) async throws
        -> FocusReminderNotificationDiagnostics {
        let snapshot = try await store.load()
        let inspection = try await gateway.inspect(
            snapshot, maximumEvidenceCount: maximumEvidenceCount
        )
        return FocusReminderNotificationDiagnostics(inspection: inspection)
    }
}

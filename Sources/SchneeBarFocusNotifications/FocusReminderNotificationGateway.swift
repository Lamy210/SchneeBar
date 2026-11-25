import Foundation
import SchneeBarFocusPersistence
import UserNotifications

public enum FocusReminderNotificationAuthorization: Equatable, Sendable {
    case notDetermined, denied, authorized, provisional, unsupported
}

/// A pair of non-atomic OS snapshots; authorization is retained so absence
/// under denied/unknown permission cannot be misread as non-delivery.
public struct FocusReminderNotificationSystemEvidence: Equatable, Sendable {
    public let authorization: FocusReminderNotificationAuthorization
    public let pendingIdentifiers: [String]
    public let deliveredIdentifiers: [String]
}

/// A sampled permission transition makes OS evidence unsuitable for a
/// single diagnostic interpretation. This is not an OS/disk transaction.
public enum FocusReminderNotificationEvidenceError: Error, Equatable, Sendable {
    case authorizationChanged
}

public struct FocusReminderNotificationInspection: Equatable, Sendable {
    public let evidence: FocusReminderNotificationSystemEvidence
    public let plan: FocusReminderNotificationReconciliationPlan
}

public struct FocusReminderNotificationRequest: Equatable, Sendable {
    public let identifier: String
    public let title: String
    public let body: String

    public init(identifier: String, title: String, body: String) {
        self.identifier = identifier
        self.title = title
        self.body = body
    }
}

/// Injected system boundary; no permission prompts or OS notifications
/// are performed without an explicit call from the eventual app owner.
public protocol FocusReminderNotificationCenterPort: Sendable {
    func authorizationStatus() async -> FocusReminderNotificationAuthorization
    func add(_ request: FocusReminderNotificationRequest) async throws
    func pendingIdentifiers() async -> [String]
    func deliveredIdentifiers() async -> [String]
    func remove(identifiers: [String]) async
}

public enum FocusReminderNotificationSubmission: Equatable, Sendable {
    /// OS accepted the request. This is not evidence of user presentation.
    case accepted
    /// No authorization request is made automatically.
    case authorizationUnavailable
}

/// Isolated and not wired to the shipping application. The coordinator must
/// first revalidate live outbox ownership, persist ACK only on .accepted,
/// and reconcile cancellation/ACK crashes before enabling actual delivery.
public actor FocusReminderNotificationGateway {
    private let center: any FocusReminderNotificationCenterPort

    public init(center: any FocusReminderNotificationCenterPort) {
        self.center = center
    }

    public init() {
        self.center = SystemFocusReminderNotificationCenter()
    }

    public nonisolated static func identifier(for outboxID: UUID) -> String {
        FocusReminderNotificationIdentity.identifier(for: outboxID)
    }

    public func submit(_ intent: FocusReminderOutboxRecord) async throws
        -> FocusReminderNotificationSubmission {
        let status = await center.authorizationStatus()
        guard status == .authorized || status == .provisional else {
            return .authorizationUnavailable
        }

        // Avoid leaking private user-entered titles or imported Runner data.
        // No sound, badge, action, URL, userInfo or content attachment.
        try await center.add(FocusReminderNotificationRequest(
            identifier: Self.identifier(for: intent.id),
            title: "Reminder",
            body: "A scheduled reminder is ready."
        ))
        return .accepted
    }

    /// Read-only OS evidence snapshot, with explicit authorization and a
    /// strict count limit. No ACK, dispatch, cancellation or permission prompt.
    /// OS pending/delivered reads are not atomic; caller must revalidate before action.
    public func observe(maximumEvidenceCount: Int = 2_048) async throws
        -> FocusReminderNotificationSystemEvidence {
        guard (1...65_536).contains(maximumEvidenceCount) else {
            throw FocusReminderNotificationReconciliationError.tooManySystemIdentifiers
        }
        let authorization = await center.authorizationStatus()
        let pending = await center.pendingIdentifiers()
        guard pending.count <= maximumEvidenceCount else {
            throw FocusReminderNotificationReconciliationError.tooManySystemIdentifiers
        }
        let delivered = await center.deliveredIdentifiers()
        guard delivered.count <= maximumEvidenceCount - pending.count else {
            throw FocusReminderNotificationReconciliationError.tooManySystemIdentifiers
        }
        // The two OS arrays are not atomic, and notification permission can
        // change while they are being read. Never publish a snapshot with
        // an authorization state contradicted by a second explicit sample.
        // Equality does not prove that the state remained stable (ABA).
        guard await center.authorizationStatus() == authorization else {
            throw FocusReminderNotificationEvidenceError.authorizationChanged
        }
        return FocusReminderNotificationSystemEvidence(
            authorization: authorization, pendingIdentifiers: pending,
            deliveredIdentifiers: delivered
        )
    }

    /// Convenience inspection only: the passed durable snapshot can be stale
    /// by the time the two OS queries complete. Never use the result alone
    /// to resend/ACK/remove a notification.
    public func inspect(
        _ snapshot: FocusReminderCollectionStore.Snapshot,
        maximumEvidenceCount: Int = 2_048
    ) async throws -> FocusReminderNotificationInspection {
        let evidence = try await observe(maximumEvidenceCount: maximumEvidenceCount)
        let plan = try snapshot.reconcileNotificationIdentifiers(
            pending: evidence.pendingIdentifiers,
            delivered: evidence.deliveredIdentifiers,
            maximumEvidenceCount: maximumEvidenceCount
        )
        return FocusReminderNotificationInspection(evidence: evidence, plan: plan)
    }

    /// Only the SchneeBar-owned Focus namespace is addressed. This does not
    /// cancel SchneeRunner or GitHub recovery notifications.
    public func cancel(outboxID: UUID) async {
        await center.remove(identifiers: [Self.identifier(for: outboxID)])
    }
}

private actor SystemFocusReminderNotificationCenter: FocusReminderNotificationCenterPort {
    private let center: UNUserNotificationCenter

    init(center: UNUserNotificationCenter = .current()) {
        self.center = center
    }

    func authorizationStatus() async -> FocusReminderNotificationAuthorization {
        let settings = await center.notificationSettings()
        switch settings.authorizationStatus {
        case .notDetermined: return .notDetermined
        case .denied: return .denied
        case .authorized: return .authorized
        case .provisional: return .provisional
        case .ephemeral: return .unsupported
        @unknown default: return .unsupported
        }
    }

    func add(_ request: FocusReminderNotificationRequest) async throws {
        let content = UNMutableNotificationContent()
        content.title = request.title
        content.body = request.body
        try await center.add(UNNotificationRequest(
            identifier: request.identifier, content: content, trigger: nil
        ))
    }

    func pendingIdentifiers() async -> [String] {
        await center.pendingNotificationRequests().map(\.identifier)
    }

    func deliveredIdentifiers() async -> [String] {
        await center.deliveredNotifications().map { $0.request.identifier }
    }

    func remove(identifiers: [String]) async {
        let owned = identifiers.filter {
            FocusReminderNotificationIdentity.parseOwned($0) != nil
        }
        guard !owned.isEmpty else { return }
        center.removePendingNotificationRequests(withIdentifiers: owned)
        center.removeDeliveredNotifications(withIdentifiers: owned)
    }
}

import Foundation
import SchneeBarFocusPersistence
import UserNotifications

public enum FocusReminderNotificationAuthorization: Equatable, Sendable {
    case notDetermined, denied, authorized, provisional, unsupported
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
        "dev.lamy.schneebar.focus.\(outboxID.uuidString.lowercased())"
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

    func remove(identifiers: [String]) async {
        let owned = identifiers.filter { $0.hasPrefix("dev.lamy.schneebar.focus.") }
        guard !owned.isEmpty else { return }
        center.removePendingNotificationRequests(withIdentifiers: owned)
        center.removeDeliveredNotifications(withIdentifiers: owned)
    }
}

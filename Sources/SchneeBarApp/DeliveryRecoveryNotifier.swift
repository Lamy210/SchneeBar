import SchneeBarCore
import UserNotifications

enum DeliveryRecoveryNotificationAuthorizationStatus: Equatable, Sendable {
    case notDetermined
    case denied
    case authorized
    case provisional
    case unsupported
}

struct DeliveryRecoveryNotificationRequest: Equatable, Sendable {
    let identifier: String
    let title: String
    let body: String
}

protocol DeliveryRecoveryNotificationCenterPort: Sendable {
    func authorizationStatus() async -> DeliveryRecoveryNotificationAuthorizationStatus
    func requestProvisionalAuthorization() async throws -> Bool
    func add(_ request: DeliveryRecoveryNotificationRequest) async throws
}

protocol DeliveryRecoveryNotifying: Sendable {
    func prepareAuthorization() async
    func deliver(_ event: DeliveryRecoveryEvent) async
}

actor DeliveryRecoveryNotifier: DeliveryRecoveryNotifying {
    private let center: any DeliveryRecoveryNotificationCenterPort

    init(
        center: any DeliveryRecoveryNotificationCenterPort =
            SystemDeliveryRecoveryNotificationCenter()
    ) {
        self.center = center
    }

    func prepareAuthorization() async {
        guard await center.authorizationStatus() == .notDetermined else {
            return
        }
        _ = try? await center.requestProvisionalAuthorization()
    }

    func deliver(_ event: DeliveryRecoveryEvent) async {
        var status = await center.authorizationStatus()

        if status == .notDetermined {
            _ = try? await center.requestProvisionalAuthorization()
            status = await center.authorizationStatus()
        }

        guard status == .authorized || status == .provisional else {
            return
        }

        let request = DeliveryRecoveryNotificationRequest(
            identifier: event.id,
            title: "Delivery recovered",
            body: "A monitored workflow succeeded after a previously observed failure."
        )
        try? await center.add(request)
    }
}

private actor SystemDeliveryRecoveryNotificationCenter:
    DeliveryRecoveryNotificationCenterPort
{
    private let center: UNUserNotificationCenter

    init(center: UNUserNotificationCenter = .current()) {
        self.center = center
    }

    func authorizationStatus() async -> DeliveryRecoveryNotificationAuthorizationStatus {
        let settings = await center.notificationSettings()

        switch settings.authorizationStatus {
        case .notDetermined:
            return .notDetermined
        case .denied:
            return .denied
        case .authorized:
            return .authorized
        case .provisional:
            return .provisional
        case .ephemeral:
            return .unsupported
        @unknown default:
            return .unsupported
        }
    }

    func requestProvisionalAuthorization() async throws -> Bool {
        try await center.requestAuthorization(options: [.alert, .provisional])
    }

    func add(_ request: DeliveryRecoveryNotificationRequest) async throws {
        let content = UNMutableNotificationContent()
        content.title = request.title
        content.body = request.body

        let notification = UNNotificationRequest(
            identifier: request.identifier,
            content: content,
            trigger: nil
        )
        try await center.add(notification)
    }
}

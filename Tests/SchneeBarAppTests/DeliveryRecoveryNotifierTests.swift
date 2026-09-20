@testable import SchneeBar
import Foundation
import SchneeBarCore
import Testing

private actor RecoveryNotificationCenterStub: DeliveryRecoveryNotificationCenterPort {
    private var statuses: [DeliveryRecoveryNotificationAuthorizationStatus]
    private var authorizationRequests = 0
    private var statusReads = 0
    private var requests: [DeliveryRecoveryNotificationRequest] = []
    private let requestAuthorizationResult: Bool
    private let addShouldFail: Bool

    init(
        statuses: [DeliveryRecoveryNotificationAuthorizationStatus],
        requestAuthorizationResult: Bool = true,
        addShouldFail: Bool = false
    ) {
        self.statuses = statuses
        self.requestAuthorizationResult = requestAuthorizationResult
        self.addShouldFail = addShouldFail
    }

    func authorizationStatus() async -> DeliveryRecoveryNotificationAuthorizationStatus {
        statusReads += 1
        guard !statuses.isEmpty else { return .denied }
        if statuses.count == 1 {
            return statuses[0]
        }
        return statuses.removeFirst()
    }

    func requestProvisionalAuthorization() async throws -> Bool {
        authorizationRequests += 1
        return requestAuthorizationResult
    }

    func add(_ request: DeliveryRecoveryNotificationRequest) async throws {
        if addShouldFail {
            throw StubError.failed
        }
        requests.append(request)
    }

    func snapshot() -> (
        authorizationRequests: Int,
        statusReads: Int,
        requests: [DeliveryRecoveryNotificationRequest]
    ) {
        (authorizationRequests, statusReads, requests)
    }

    private enum StubError: Error {
        case failed
    }
}

@Test
func recoveryNotifierRequestsProvisionalAuthorizationWhenUndetermined() async {
    let center = RecoveryNotificationCenterStub(statuses: [.notDetermined])
    let notifier = DeliveryRecoveryNotifier(center: center)

    await notifier.prepareAuthorization()

    let snapshot = await center.snapshot()
    #expect(snapshot.authorizationRequests == 1)
    #expect(snapshot.statusReads == 1)
}

@Test
func recoveryNotifierSchedulesOnlyAuthorizedOrProvisionalDelivery() async throws {
    let authorizedCenter = RecoveryNotificationCenterStub(statuses: [.authorized])
    let provisionalCenter = RecoveryNotificationCenterStub(statuses: [.provisional])
    let deniedCenter = RecoveryNotificationCenterStub(statuses: [.denied])
    let event = try recoveryNotificationEvent()

    await DeliveryRecoveryNotifier(center: authorizedCenter).deliver(event)
    await DeliveryRecoveryNotifier(center: provisionalCenter).deliver(event)
    await DeliveryRecoveryNotifier(center: deniedCenter).deliver(event)

    #expect(await authorizedCenter.snapshot().requests.count == 1)
    #expect(await provisionalCenter.snapshot().requests.count == 1)
    #expect(await deniedCenter.snapshot().requests.isEmpty)
}

@Test
func recoveryNotifierRechecksSettingsAfterProvisionalRequestBeforeDelivery() async throws {
    let center = RecoveryNotificationCenterStub(
        statuses: [.notDetermined, .provisional]
    )
    let notifier = DeliveryRecoveryNotifier(center: center)

    await notifier.deliver(try recoveryNotificationEvent())

    let snapshot = await center.snapshot()
    #expect(snapshot.authorizationRequests == 1)
    #expect(snapshot.statusReads == 2)
    #expect(snapshot.requests.count == 1)
}

@Test
func recoveryNotifierUsesImmediatePrivacyMinimizedRequest() async throws {
    let center = RecoveryNotificationCenterStub(statuses: [.authorized])
    let notifier = DeliveryRecoveryNotifier(center: center)
    let event = try recoveryNotificationEvent()

    await notifier.deliver(event)

    let request = try #require(await center.snapshot().requests.first)
    #expect(request.identifier == event.id)
    #expect(request.title == "Delivery recovered")
    #expect(
        request.body
            == "A monitored workflow succeeded after a previously observed failure."
    )

    let exposed = [request.title, request.body].joined(separator: " ")
    #expect(!exposed.contains("acme/private-repo"))
    #expect(!exposed.contains("PR #47"))
    #expect(!exposed.contains("feature/secret"))
    #expect(!exposed.contains("CI"))
    #expect(!exposed.contains("github.com"))
}

@Test
func recoveryNotifierSwallowsSchedulingFailure() async throws {
    let center = RecoveryNotificationCenterStub(
        statuses: [.authorized],
        addShouldFail: true
    )
    let notifier = DeliveryRecoveryNotifier(center: center)

    await notifier.deliver(try recoveryNotificationEvent())

    #expect(await center.snapshot().statusReads == 1)
}

private func recoveryNotificationEvent() throws -> DeliveryRecoveryEvent {
    DeliveryRecoveryEvent(
        id: "github-delivery-recovery:42:41:pull_request:47:102",
        repository: "acme/private-repo",
        title: "CI recovered",
        detail: "PR #47 succeeded on feature/secret",
        destinationURL: try #require(
            URL(string: "https://github.com/acme/private-repo/actions/runs/102")
        ),
        occurredAt: Date(timeIntervalSince1970: 200)
    )
}

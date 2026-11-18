import Foundation
@testable import SchneeBarCompanionEvents
import Testing

@MainActor
private final class SubscriptionProbe {
    var callbacks: [UUID: [CompanionLocalEventSessionOwner.Receive]] = [:]
    var actions: [String] = []

    func open(_ session: UUID, _ receive: @escaping CompanionLocalEventSessionOwner.Receive)
        -> CompanionLocalEventSessionOwner.Stop {
        actions.append("open-" + session.uuidString)
        callbacks[session, default: []].append(receive)
        return { [weak self] in
            self?.actions.append("close-" + session.uuidString)
            // A late transport callback during removal must also be rejected.
            receive(session, .build, "late")
        }
    }
}

@Test @MainActor func eventSessionOwnerReplacesAndRejectsLateCallbacks() throws {
    let probe = SubscriptionProbe()
    var received: [UUID] = []
    let owner = CompanionLocalEventSessionOwner(open: { probe.open($0, $1) },
        receive: { session, _, _ in received.append(session) })
    let first = UUID(), second = UUID()
    owner.update(session: nil)
    #expect(probe.actions.isEmpty)
    owner.update(session: first)
    owner.update(session: first)
    let old = try #require(probe.callbacks[first]?.first)
    old(first, .build, "valid")
    old(second, .build, "wrong session")
    owner.update(session: second)
    old(first, .build, "stale")
    let current = try #require(probe.callbacks[second]?.first)
    current(second, .build, "valid")
    owner.stop()
    current(second, .build, "stale")
    owner.stop()
    #expect(received == [first, second])
    #expect(probe.actions == [
        "open-" + first.uuidString, "close-" + first.uuidString,
        "open-" + second.uuidString, "close-" + second.uuidString
    ])
    owner.update(session: first)
    old(first, .build, "stale reused UUID")
    let renewed = try #require(probe.callbacks[first]?.last)
    renewed(first, .build, "new generation")
    #expect(received == [first, second, first])
    owner.stop()
}

@Test @MainActor func eventSessionOwnerClosesRegistrationRevokedWhileOpening() {
    let id = UUID()
    var closes = 0
    var deliveries = 0
    var revoke: (@MainActor () -> Void)?
    let owner = CompanionLocalEventSessionOwner(open: { session, callback in
        callback(session, .build, nil)
        return { closes += 1 }
    }, receive: { _, _, _ in
        deliveries += 1
        revoke?()
    })
    revoke = { [weak owner] in owner?.stop() }
    owner.update(session: id)
    #expect(deliveries == 1)
    #expect(closes == 1)
    #expect(owner.session == nil)
    owner.stop()
    #expect(closes == 1)
}

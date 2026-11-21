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


@Test @MainActor func eventSessionOwnerSerializesReplacementDuringOpen() throws {
    let first = UUID(), second = UUID()
    var active = 0, peak = 0
    var actions: [String] = []
    var deliveries: [UUID] = []
    var replace: (@MainActor () -> Void)?
    var old: CompanionLocalEventSessionOwner.Receive?
    let owner = CompanionLocalEventSessionOwner(open: { id, callback in
        active += 1
        peak = max(peak, active)
        actions.append("open-" + id.uuidString)
        if id == first {
            old = callback
            callback(id, .build, nil)
            // Replacement invalidates the old callback immediately, even
            // though open has yet to return its cancellation closure.
            callback(id, .build, nil)
        }
        return {
            actions.append("close-" + id.uuidString)
            active -= 1
        }
    }, receive: { id, _, _ in
        deliveries.append(id)
        if id == first { replace?() }
    })
    replace = { [weak owner] in owner?.update(session: second) }
    owner.update(session: first)
    #expect(owner.session == second && active == 1 && peak == 1)
    #expect(actions == ["open-" + first.uuidString, "close-" + first.uuidString, "open-" + second.uuidString])
    let stale = try #require(old)
    stale(first, .build, nil)
    #expect(deliveries == [first])
    owner.stop()
    #expect(active == 0)
}

@Test @MainActor func eventSessionOwnerCoalescesReplacementDuringCloseAndRejectsReusedUUID() throws {
    let first = UUID(), skipped = UUID()
    var active = 0, peak = 0, opens = 0
    var actions: [String] = []
    var callbacks: [CompanionLocalEventSessionOwner.Receive] = []
    var deliveries = 0
    var duringClose: (@MainActor () -> Void)?
    let owner = CompanionLocalEventSessionOwner(open: { id, callback in
        opens += 1
        active += 1
        peak = max(peak, active)
        actions.append("open-" + id.uuidString)
        callbacks.append(callback)
        return {
            actions.append("close-start-" + id.uuidString)
            callback(id, .build, nil)
            duringClose?()
            active -= 1
            actions.append("close-end-" + id.uuidString)
        }
    }, receive: { _, _, _ in deliveries += 1 })
    owner.update(session: first)
    duringClose = { [weak owner] in owner?.update(session: first) }
    owner.update(session: skipped)
    #expect(owner.session == first && active == 1 && peak == 1 && opens == 2)
    #expect(actions == ["open-" + first.uuidString, "close-start-" + first.uuidString,
        "close-end-" + first.uuidString, "open-" + first.uuidString])
    let old = try #require(callbacks.first)
    let renewed = try #require(callbacks.last)
    old(first, .build, nil)
    renewed(first, .build, nil)
    #expect(deliveries == 1)
    duringClose = nil
    owner.stop()
    #expect(active == 0)
}

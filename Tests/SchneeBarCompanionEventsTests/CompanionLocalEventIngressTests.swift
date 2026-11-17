import Foundation
import SchneeBarCompanionCore
import SchneeBarCompanionEvents
import Testing

private struct Fixture {
    var ingress = CompanionLocalEventIngress()
    var arbitration = CompanionArbitration()

    mutating func send(_ json: String, at seconds: Double = 0,
                       kind: CompanionLocalEventIngress.Kind = .character) -> CompanionLocalEventIngress.Outcome {
        ingress.receive(kind: kind, payload: Data(json.utf8), at: .seconds(seconds), arbitration: &arbitration)
    }

    mutating func set(_ channel: String, at seconds: Double = 0, duration: String = "1800") -> CompanionLocalEventIngress.Outcome {
        send("{\"action\":\"set\",\"state\":\"dash\",\"channel\":\"\(channel)\",\"durationSeconds\":\(duration)}", at: seconds)
    }

    mutating func clear(_ channel: String, at seconds: Double = 0) -> CompanionLocalEventIngress.Outcome {
        send("{\"action\":\"clear\",\"channel\":\"\(channel)\"}", at: seconds)
    }

    mutating func advance(_ seconds: Double) {
        let advanced = ingress.advance(to: .seconds(seconds), arbitration: &arbitration)
        #expect(advanced)
    }
}

@Test func localEventByteAndUTF8Admission() {
    var f = Fixture()
    let event = "{\"action\":\"set\",\"state\":\"walk\"}"
    let exact = event + String(repeating: " ", count: 4096 - event.utf8.count)
    #expect(f.send(exact) == .accepted)
    #expect(f.send(exact + " ") == .oversized)
    #expect(f.ingress.receive(kind: .character, payload: Data([0xff]), at: .zero, arbitration: &f.arbitration) == .malformed)
    #expect(f.arbitration.state == .walk)
}

@Test func rejectsUntrustedCommandAndMalformedSchemas() {
    var f = Fixture()
    for json in [
        "{\"action\":\"set\",\"state\":\"dash\",\"command\":\"rerun\"}",
        "{\"action\":\"set\",\"state\":\"unknown\"}",
        "{\"action\":\"clear\",\"state\":\"idle\"}",
        "{\"action\":\"set\",\"state\":\"dash\",\"durationSeconds\":true}",
        "{\"action\":\"set\",\"state\":\"dash\",\"durationSeconds\":0.09}",
        "{\"action\":\"set\",\"state\":\"dash\",\"durationSeconds\":3601}",
        "{\"action\":\"set\",\"state\":\"dash\",\"channel\":\"a/b\"}",
        "{\"action\":\"set\",\"state\":\"dash\",\"channel\":\"\(String(repeating: "あ", count: 22))\"}"
    ] { #expect(f.send(json) == .malformed) }
    #expect(f.send("{\"phase\":\"started\",\"command\":\"run\"}", kind: .build) == .malformed)
    #expect(f.ingress.activeLocalCount == 0)
    #expect(f.arbitration.winningSource == nil)
}

@Test func legacyBuildPhasesUseFiniteLeasesAndReservedLane() {
    var f = Fixture()
    #expect(f.send("{\"phase\":\"started\"}", kind: .build) == .accepted)
    #expect(f.arbitration.state == .dash)
    #expect(f.arbitration.nextDeadline == .seconds(1800))
    #expect(f.send("{\"phase\":\"succeeded\"}", at: 1, kind: .build) == .accepted)
    #expect(f.arbitration.state == .sprint)
    f.advance(3)
    #expect(f.arbitration.state == .run)
    #expect(f.ingress.activeLocalCount == 0)
    #expect(f.send("{\"phase\":\"failed\"}", at: 3, kind: .build) == .accepted)
    #expect(f.arbitration.nextDeadline == .seconds(8))
    #expect(f.send("{\"phase\":\"cancelled\"}", at: 4, kind: .build) == .accepted)
    #expect(f.arbitration.winningSource == nil)
}

@Test func terminalReserveClearsLocalOnlyAndQuarantines() {
    var f = Fixture()
    let cpu = f.arbitration.submit(.walk, from: .cpu, at: .zero)
    #expect(cpu)
    let manual = f.arbitration.submit(.idle, from: .manual, at: .zero)
    #expect(manual)
    for i in 0..<12 { #expect(f.set("channel-\(i)") == .accepted) }
    #expect(f.set("overflow") == .updateLimited)
    for i in 0..<4 { #expect(f.clear("channel-\(i)") == .accepted) }
    #expect(f.ingress.activeLocalCount == 8)
    #expect(f.clear("channel-4") == .localStateCleared)
    #expect(f.ingress.activeLocalCount == 0)
    #expect(f.arbitration.state == .idle)
    #expect(f.set("new", at: 0.999) == .quarantined)
    let cleared = f.arbitration.clear(.manual, at: .seconds(1))
    #expect(cleared)
    #expect(f.arbitration.state == .walk)
    #expect(f.set("new", at: 1) == .accepted)
}

@Test func malformedRawFloodClearsLocalAt129thAttempt() {
    var f = Fixture()
    #expect(f.set("active") == .accepted)
    for _ in 0..<127 { #expect(f.send("!") == .malformed) }
    #expect(f.ingress.activeLocalCount == 1)
    #expect(f.send("!") == .localStateCleared)
    #expect(f.arbitration.state == .run)
    #expect(f.set("active", at: 0.5) == .quarantined)
    #expect(f.set("active", at: 1) == .accepted)
}

@Test func sharedBuildAndChannelCapacityRecoversAfterExpiry() {
    var f = Fixture()
    for i in 0..<64 { #expect(f.set("c\(i)", at: Double(i / 12), duration: "10") == .accepted) }
    #expect(f.ingress.activeLocalCount == 64)
    #expect(f.set("overflow", at: 6) == .capacityLimited)
    #expect(f.send("{\"phase\":\"started\"}", at: 6, kind: .build) == .capacityLimited)
    #expect(f.set("c0", at: 6, duration: "10") == .accepted)
    f.advance(10)
    #expect(f.ingress.activeLocalCount == 53)
    #expect(f.send("{\"phase\":\"started\"}", at: 10, kind: .build) == .accepted)
    #expect(f.ingress.activeLocalCount == 54)
}

@Test func renewalDroppedUpdateAndRegressedClockDoNotResurrect() {
    var f = Fixture()
    #expect(f.set("active", duration: "2") == .accepted)
    for i in 0..<11 { #expect(f.set("short-\(i)", duration: "0.1") == .accepted) }
    #expect(f.set("active", at: 0.5, duration: "3600") == .updateLimited)
    f.advance(2)
    #expect(f.ingress.activeLocalCount == 0)
    #expect(f.set("old", at: 1) == .staleClock)
    #expect(f.arbitration.state == .run)
    #expect(f.set("active", at: 2, duration: "2") == .accepted)
    let identity = f.arbitration.winningSource
    #expect(f.set("active", at: 3, duration: "2") == .accepted)
    #expect(f.arbitration.winningSource == identity)
    f.advance(4)
    #expect(f.arbitration.state == .dash)
    f.advance(5)
    #expect(f.arbitration.state == .run)
}

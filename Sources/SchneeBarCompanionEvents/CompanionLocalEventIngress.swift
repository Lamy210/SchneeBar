import Foundation
import CoreFoundation
import SchneeBarCompanionCore

/// A synchronous, single-owner adapter; no notification observers, timers,
/// credentials or API operations. The owner serializes all calls and is the
/// only writer of local sources in the supplied arbitration value.
public struct CompanionLocalEventIngress: Sendable {
    public enum Kind: String, Sendable {
        case character = "com.schneerunner.character-state-event.v1"
        case build = "com.schneerunner.build-event.v1"
    }

    public enum Outcome: Equatable, Sendable {
        case accepted, malformed, oversized, updateLimited, capacityLimited
        case quarantined, localStateCleared, staleClock
    }

    private enum Event {
        case set(String, CompanionState, Duration)
        case clear(String)
        case build(CompanionState?, Duration?, terminal: Bool)

        var terminal: Bool {
            switch self {
            case .set: false
            case .clear: true
            case let .build(_, _, terminal): terminal
            }
        }
    }

    private struct Channel: Sendable {
        let id: UUID
        let deadline: Duration
    }

    private var channels: [String: Channel] = [:]
    private var buildDeadline: Duration?
    private var attempts: [Duration] = []
    private var updates: [Duration] = []
    private var terminals: [Duration] = []
    private var quarantinedUntil: Duration?
    private var time: Duration = .zero

    public init() {}

    public var activeLocalCount: Int { channels.count + (buildDeadline == nil ? 0 : 1) }

    /// Reconcile on the current local monotonic clock, including wake/expiry.
    @discardableResult
    public mutating func advance(to now: Duration, arbitration: inout CompanionArbitration) -> Bool {
        guard now >= time, arbitration.advance(to: now) else { return false }
        time = now
        channels = channels.filter { $0.value.deadline > now }
        if let buildDeadline, buildDeadline <= now { self.buildDeadline = nil }
        return true
    }

    /// Call at entry to a serialized listener, before allocating a JSON object.
    /// Data is already received by the caller; the 4096-byte limit is not an
    /// OS transport allocation limit. Every attempt, including malformed data,
    /// counts toward the raw window. Legacy v1 has no sender sequence or nonce.
    @discardableResult
    public mutating func receive(
        kind: Kind, payload: Data, at now: Duration, arbitration: inout CompanionArbitration
    ) -> Outcome {
        guard now >= time else { return .staleClock }
        // During quarantine do no JSON parsing or arbitration scan.
        if let quarantinedUntil, now < quarantinedUntil { return .quarantined }
        guard advance(to: now, arbitration: &arbitration) else { return .staleClock }
        quarantinedUntil = nil
        Self.expire(&attempts, at: now)
        guard attempts.count < 128 else { return failClosed(at: now, arbitration: &arbitration) }
        attempts.append(now)
        guard payload.count <= 4096 else { return .oversized }
        guard let event = Self.parse(kind, payload) else { return .malformed }

        Self.expire(&updates, at: now)
        Self.expire(&terminals, at: now)
        if event.terminal {
            guard terminals.count < 4 else { return failClosed(at: now, arbitration: &arbitration) }
            terminals.append(now)
        } else {
            guard updates.count < 12 else { return .updateLimited }
            updates.append(now)
        }
        switch event {
        case let .set(channel, state, duration):
            guard channels[channel] != nil || activeLocalCount < 64 else { return .capacityLimited }
            let id = channels[channel]?.id ?? UUID()
            let deadline = now + duration
            guard arbitration.submit(state, from: .localState(id), at: now, until: deadline) else {
                return .capacityLimited
            }
            channels[channel] = Channel(id: id, deadline: deadline)
        case let .clear(channel):
            if let entry = channels.removeValue(forKey: channel) {
                arbitration.clear(.localState(entry.id), at: now)
            }
        case let .build(state, duration, _):
            if let state, let duration {
                guard buildDeadline != nil || activeLocalCount < 64 else { return .capacityLimited }
                let deadline = now + duration
                guard arbitration.submit(state, from: .localBuild, at: now, until: deadline) else {
                    return .capacityLimited
                }
                buildDeadline = deadline
            } else {
                arbitration.clear(.localBuild, at: now)
                buildDeadline = nil
            }
        }
        return .accepted
    }

    private static func expire(_ times: inout [Duration], at now: Duration) {
        times.removeAll { now - $0 >= .seconds(1) }
    }

    private mutating func failClosed(at now: Duration, arbitration: inout CompanionArbitration) -> Outcome {
        arbitration.clearLocal(at: now)
        channels.removeAll()
        buildDeadline = nil
        attempts.removeAll()
        updates.removeAll()
        terminals.removeAll()
        quarantinedUntil = now + .seconds(1)
        return .localStateCleared
    }

    private static func parse(_ kind: Kind, _ data: Data) -> Event? {
        guard !data.isEmpty, !data.contains(0), String(data: data, encoding: .utf8) != nil,
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        switch kind {
        case .build:
            guard Set(object.keys) == ["phase"], let phase = object["phase"] as? String else { return nil }
            switch phase {
            case "started": return .build(.dash, .seconds(1800), terminal: false)
            case "succeeded": return .build(.sprint, .seconds(2), terminal: true)
            case "failed": return .build(.idle, .seconds(5), terminal: true)
            case "cancelled": return .build(nil, nil, terminal: true)
            default: return nil
            }
        case .character:
            guard Set(object.keys).isSubset(of: ["action", "state", "durationSeconds", "channel"]),
                  let action = object["action"] as? String else { return nil }
            let channel: String
            if let raw = object["channel"], !(raw is NSNull) {
                guard let value = raw as? String else { return nil }
                channel = value
            } else { channel = "default" }
            guard !channel.isEmpty, channel.utf8.count <= 64,
                  channel.unicodeScalars.allSatisfy({ CharacterSet.alphanumerics.contains($0) || "._-".unicodeScalars.contains($0) }) else { return nil }
            let rawState = object["state"]
            let rawDuration = object["durationSeconds"]
            if action == "clear" {
                guard rawState == nil || rawState is NSNull,
                      rawDuration == nil || rawDuration is NSNull else { return nil }
                return .clear(channel)
            }
            guard action == "set", let label = rawState as? String else { return nil }
            let state: CompanionState
            switch label {
            case "idle": state = .idle
            case "walk": state = .walk
            case "run": state = .run
            case "dash": state = .dash
            case "sprint": state = .sprint
            default: return nil
            }
            let duration: Double
            if let rawDuration, !(rawDuration is NSNull) {
                guard let number = rawDuration as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
                      number.doubleValue.isFinite, (0.1...3600).contains(number.doubleValue) else { return nil }
                duration = number.doubleValue
            } else { duration = 1800 }
            return .set(channel, state, .seconds(duration))
        }
    }
}

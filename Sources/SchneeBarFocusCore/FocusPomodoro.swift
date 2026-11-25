import Foundation

/// Native finite Pomodoro session. Each phase has one absolute deadline.
/// Completing a phase does not automatically start its successor.
public struct FocusPomodoro: Equatable, Sendable, Codable {
    public enum Kind: String, Equatable, Sendable, Codable {
        case focus, shortBreak, longBreak
    }

    public enum ValidationError: Error, Equatable, Sendable {
        case invalidPlan, invalidRecord, unsupportedVersion, stalePhase, phaseNotCompleted, sessionEnded
    }

    public struct Plan: Equatable, Sendable, Codable {
        public static let maximumRounds = 12
        public let rounds: Int
        public let focus: TimeInterval
        public let shortBreak: TimeInterval
        public let longBreak: TimeInterval
        public let longBreakEvery: Int

        public init(rounds: Int = 4, focus: TimeInterval = 1500,
                    shortBreak: TimeInterval = 300, longBreak: TimeInterval = 900,
                    longBreakEvery: Int = 4) throws {
            guard (1...Self.maximumRounds).contains(rounds),
                  (1...Self.maximumRounds).contains(longBreakEvery),
                  [focus, shortBreak, longBreak].allSatisfy({
                      $0.isFinite && $0 >= 1 && $0 <= FocusCountdown.maximumDuration
                  }) else { throw ValidationError.invalidPlan }
            self.rounds = rounds
            self.focus = focus
            self.shortBreak = shortBreak
            self.longBreak = longBreak
            self.longBreakEvery = longBreakEvery
        }

        private enum CodingKeys: String, CodingKey { case rounds, focus, shortBreak, longBreak, longBreakEvery }

        public init(from decoder: Decoder) throws {
            let record = try decoder.container(keyedBy: CodingKeys.self)
            try self.init(rounds: record.decode(Int.self, forKey: .rounds),
                          focus: record.decode(TimeInterval.self, forKey: .focus),
                          shortBreak: record.decode(TimeInterval.self, forKey: .shortBreak),
                          longBreak: record.decode(TimeInterval.self, forKey: .longBreak),
                          longBreakEvery: record.decode(Int.self, forKey: .longBreakEvery))
        }

        fileprivate func kind(at step: Int) -> Kind {
            if step.isMultiple(of: 2) { return .focus }
            return (step / 2 + 1).isMultiple(of: longBreakEvery) ? .longBreak : .shortBreak
        }

        fileprivate func duration(at step: Int) -> TimeInterval {
            switch kind(at: step) {
            case .focus: focus
            case .shortBreak: shortBreak
            case .longBreak: longBreak
            }
        }
    }

    public struct Completion: Equatable, Sendable {
        public let sessionID: UUID
        public let step: Int
        public let kind: Kind
        public let countdown: FocusCountdown.Completion
        public let finishesSession: Bool
    }

    public let id: UUID
    public let plan: Plan
    public private(set) var step: Int
    public private(set) var countdown: FocusCountdown
    public private(set) var isCancelled: Bool

    public var round: Int { step / 2 + 1 }
    public var kind: Kind { plan.kind(at: step) }
    private var finalStep: Bool { step == 2 * (plan.rounds - 1) }

    public var isFinished: Bool {
        guard !isCancelled, finalStep, case .completed = countdown.phase else { return false }
        return true
    }

    public var canAdvance: Bool {
        guard !isCancelled, !finalStep, case .completed = countdown.phase else { return false }
        return true
    }

    public init(id: UUID = UUID(), plan: Plan, now: Date) throws {
        self.id = id
        self.plan = plan
        self.step = 0
        self.countdown = try FocusCountdown(duration: plan.focus, now: now)
        self.isCancelled = false
    }

    private func requireCurrent(_ expectedStep: Int) throws {
        guard expectedStep == step else { throw ValidationError.stalePhase }
        guard !isCancelled && !isFinished else { throw ValidationError.sessionEnded }
    }

    private func event(_ completion: FocusCountdown.Completion?) -> Completion? {
        completion.map { .init(sessionID: id, step: step, kind: kind,
                               countdown: $0, finishesSession: isFinished) }
    }

    @discardableResult
    public mutating func reconcile(at now: Date) throws -> Completion? {
        guard !isCancelled else { return nil }
        let completed = try countdown.reconcile(at: now)
        return event(completed)
    }

    @discardableResult
    public mutating func pause(step expectedStep: Int, at now: Date) throws -> Completion? {
        try requireCurrent(expectedStep)
        let completed = try countdown.pause(at: now)
        return event(completed)
    }

    public mutating func resume(step expectedStep: Int, at now: Date) throws {
        try requireCurrent(expectedStep)
        try countdown.resume(at: now)
    }

    /// Explicitly start the next phase from now, never a past deadline.
    public mutating func advance(step expectedStep: Int, at now: Date) throws {
        try requireCurrent(expectedStep)
        guard canAdvance else { throw ValidationError.phaseNotCompleted }
        let next = step + 1
        let timer = try FocusCountdown(duration: plan.duration(at: next), now: now)
        step = next
        countdown = timer
    }

    /// Expiry wins over cancellation of the final focus. An intermediate
    /// overdue phase completes once, then the remaining session is cancelled.
    @discardableResult
    public mutating func cancel(step expectedStep: Int, at now: Date) throws -> Completion? {
        try requireCurrent(expectedStep)
        let completed = try countdown.cancel(at: now)
        if !isFinished { isCancelled = true }
        return event(completed)
    }

    private enum CodingKeys: String, CodingKey { case version, id, plan, step, countdown, isCancelled }

    public init(from decoder: Decoder) throws {
        let record = try decoder.container(keyedBy: CodingKeys.self)
        guard try record.decode(Int.self, forKey: .version) == 1 else {
            throw ValidationError.unsupportedVersion
        }
        let plan = try record.decode(Plan.self, forKey: .plan)
        let step = try record.decode(Int.self, forKey: .step)
        let countdown = try record.decode(FocusCountdown.self, forKey: .countdown)
        let cancelled = try record.decode(Bool.self, forKey: .isCancelled)
        guard (0...(2 * (plan.rounds - 1))).contains(step),
              countdown.duration == plan.duration(at: step) else { throw ValidationError.invalidRecord }
        switch countdown.phase {
        case .cancelled:
            guard cancelled else { throw ValidationError.invalidRecord }
        case .running, .paused:
            guard !cancelled else { throw ValidationError.invalidRecord }
        case .completed:
            guard !cancelled || step != 2 * (plan.rounds - 1) else { throw ValidationError.invalidRecord }
        }
        self.id = try record.decode(UUID.self, forKey: .id)
        self.plan = plan
        self.step = step
        self.countdown = countdown
        self.isCancelled = cancelled
    }

    public func encode(to encoder: Encoder) throws {
        var record = encoder.container(keyedBy: CodingKeys.self)
        try record.encode(1, forKey: .version)
        try record.encode(id, forKey: .id)
        try record.encode(plan, forKey: .plan)
        try record.encode(step, forKey: .step)
        try record.encode(countdown, forKey: .countdown)
        try record.encode(isCancelled, forKey: .isCancelled)
    }
}

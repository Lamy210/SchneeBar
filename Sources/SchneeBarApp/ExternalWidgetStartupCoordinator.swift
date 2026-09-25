import SchneeBarCore

@MainActor
final class ExternalWidgetStartupCoordinator {
    typealias Register = @Sendable (WidgetEngine) async throws
        -> ExternalWidgetStartupRegistrationResult

    private let register: Register?
    private(set) var isFinished = false
    private var attemptSequence: UInt64 = 0
    private var activeAttemptID: UInt64?

    init(registrar: ExternalWidgetStartupRegistrar?) {
        if let registrar {
            register = { engine in
                try await registrar.loadAndRegister(in: engine)
            }
        } else {
            register = nil
        }
    }

    init(register: Register?) {
        self.register = register
    }

    func runIfNeeded(
        in engine: WidgetEngine,
        model: WidgetRuntimeModel,
        isCurrent: @MainActor () -> Bool
    ) async throws {
        guard !isFinished,
              activeAttemptID == nil,
              let register,
              isCurrent()
        else {
            return
        }

        attemptSequence &+= 1
        let attemptID = attemptSequence
        activeAttemptID = attemptID
        defer {
            if activeAttemptID == attemptID {
                activeAttemptID = nil
            }
        }

        model.externalWidgetStartupHealth = .loading

        do {
            let result = try await register(engine)
            try Task.checkCancellation()
            guard activeAttemptID == attemptID,
                  isCurrent()
            else {
                return
            }

            model.externalWidgetStartupHealth =
                ExternalWidgetStartupHealthPolicy.terminalHealth(for: result)
            isFinished = true
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            try Task.checkCancellation()
            guard activeAttemptID == attemptID,
                  isCurrent()
            else {
                return
            }
            model.externalWidgetStartupHealth = .unavailable(.unknown)
            isFinished = true
        }
    }

    func handleSleep(model: WidgetRuntimeModel) {
        if !isFinished {
            activeAttemptID = nil
        }
        model.externalWidgetStartupHealth =
            ExternalWidgetStartupHealthPolicy.healthAfterSleep(
                current: model.externalWidgetStartupHealth,
                startupFinished: isFinished
            )
    }
}

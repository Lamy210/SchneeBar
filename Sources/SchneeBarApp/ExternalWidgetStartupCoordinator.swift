import SchneeBarCore

@MainActor
final class ExternalWidgetStartupCoordinator {
    typealias Register = @Sendable (WidgetEngine) async throws
        -> ExternalWidgetStartupRegistrationResult

    private let register: Register?
    private var nextAttemptID: UInt64 = 0
    private var activeAttemptID: UInt64?
    private(set) var isFinished = false

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

        nextAttemptID &+= 1
        let attemptID = nextAttemptID
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

            model.externalWidgetStartupHealth = health(for: result)
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
        guard !isFinished else {
            return
        }
        activeAttemptID = nil
        model.externalWidgetStartupHealth = .notAttempted
    }

    private func health(
        for result: ExternalWidgetStartupRegistrationResult
    ) -> ExternalWidgetStartupHealth {
        switch result {
        case let .loaded(widgetCount):
            return .loaded(widgetCount: widgetCount)
        case let .unavailable(reason):
            return .unavailable(reason)
        }
    }
}

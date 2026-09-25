import SchneeBarCore

@MainActor
final class ExternalWidgetStartupCoordinator {
    typealias Register = @Sendable (WidgetEngine) async throws
        -> ExternalWidgetStartupRegistrationResult

    private let register: Register?
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
              let register,
              isCurrent()
        else {
            return
        }

        model.externalWidgetStartupHealth = .loading

        do {
            let result = try await register(engine)
            try Task.checkCancellation()
            guard isCurrent() else {
                return
            }

            model.externalWidgetStartupHealth =
                ExternalWidgetStartupHealthPolicy.terminalHealth(for: result)
            isFinished = true
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            try Task.checkCancellation()
            guard isCurrent() else {
                return
            }
            model.externalWidgetStartupHealth = .unavailable(.unknown)
            isFinished = true
        }
    }

    func handleSleep(model: WidgetRuntimeModel) {
        model.externalWidgetStartupHealth =
            ExternalWidgetStartupHealthPolicy.healthAfterSleep(
                current: model.externalWidgetStartupHealth,
                startupFinished: isFinished
            )
    }
}

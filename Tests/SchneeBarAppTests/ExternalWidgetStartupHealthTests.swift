import SchneeBarCore
import Testing
@testable import SchneeBar

private actor StartupHealthPreferencesStore: WidgetPreferencesStore {
    func load() async throws -> WidgetConfiguration {
        WidgetConfiguration()
    }

    func save(_ configuration: WidgetConfiguration) async throws {}
}

@Test @MainActor
func externalWidgetStartupHealthBeginsNotAttempted() {
    let model = WidgetRuntimeModel(
        preferencesStore: StartupHealthPreferencesStore()
    )

    #expect(model.externalWidgetStartupHealth == .notAttempted)
}

@Test
func cancellationIsNeverClassifiedAsUnavailableStartupHealth() async throws {
    let engine = WidgetEngine()
    let registrar = ExternalWidgetStartupRegistrar(
        loadDefinitions: {
            throw CancellationError()
        },
        classifyFailure: { _ in
            Issue.record(
                "Cancellation must bypass failure classification"
            )
            return .unknown
        }
    )

    await #expect(throws: CancellationError.self) {
        try await registrar.loadAndRegister(in: engine)
    }
}

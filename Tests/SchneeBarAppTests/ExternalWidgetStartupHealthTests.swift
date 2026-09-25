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

@Test
func staleRuntimeGenerationCannotPublishTerminalStartupHealth() throws {
    var lifecycle = WidgetRuntimeLifecycle()
    let firstGeneration = try #require(lifecycle.beginRuntime())

    lifecycle.willSleep()
    let currentGeneration = try #require(lifecycle.didWake())

    #expect(
        ExternalWidgetStartupHealthPolicy.terminalHealth(
            for: .loaded(widgetCount: 2),
            generation: firstGeneration,
            lifecycle: lifecycle
        ) == nil
    )
    #expect(
        ExternalWidgetStartupHealthPolicy.terminalHealth(
            for: .loaded(widgetCount: 2),
            generation: currentGeneration,
            lifecycle: lifecycle
        ) == .loaded(widgetCount: 2)
    )
}

@Test
func unfinishedStartupReturnsToNotAttemptedAfterSleep() {
    #expect(
        ExternalWidgetStartupHealthPolicy.healthAfterSleep(
            current: .loading,
            startupFinished: false
        ) == .notAttempted
    )
}

@Test
func completedStartupHealthSurvivesSleep() {
    #expect(
        ExternalWidgetStartupHealthPolicy.healthAfterSleep(
            current: .loaded(widgetCount: 3),
            startupFinished: true
        ) == .loaded(widgetCount: 3)
    )
}

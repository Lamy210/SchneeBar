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
    let firstGenerationCandidate = lifecycle.beginRuntime()
    let firstGeneration = try #require(firstGenerationCandidate)

    lifecycle.willSleep()
    let currentGenerationCandidate = lifecycle.didWake()
    let currentGeneration = try #require(currentGenerationCandidate)

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


@Test
func externalWidgetStartupPresentationIsSanitizedAndStable() {
    #expect(
        ExternalWidgetStartupHealth.notAttempted.settingsPresentation
            == ExternalWidgetStartupHealthPresentation(
                status: "Not loaded",
                detail: "External widgets have not been loaded in this app session.",
                systemImage: "circle.dashed"
            )
    )
    #expect(
        ExternalWidgetStartupHealth.loading.settingsPresentation
            == ExternalWidgetStartupHealthPresentation(
                status: "Loading",
                detail: "External widget documents are being validated before registration.",
                systemImage: "hourglass"
            )
    )
    #expect(
        ExternalWidgetStartupHealth.loaded(widgetCount: 0).settingsPresentation
            == ExternalWidgetStartupHealthPresentation(
                status: "No external widgets",
                detail: "Startup validation completed without registering external widgets.",
                systemImage: "checkmark.circle"
            )
    )
    #expect(
        ExternalWidgetStartupHealth.loaded(widgetCount: 2).settingsPresentation
            == ExternalWidgetStartupHealthPresentation(
                status: "Loaded",
                detail: "2 external widgets registered. Saved preferences are preserved; newly discovered external widgets default to disabled.",
                systemImage: "checkmark.circle"
            )
    )
}

@Test(arguments: [
    (ExternalWidgetStartupFailureReason.unsafeStorage, "External widget storage did not pass safety checks."),
    (ExternalWidgetStartupFailureReason.resourceLimit, "External widget storage exceeded configured safety limits."),
    (ExternalWidgetStartupFailureReason.invalidDocuments, "One or more external widget documents are invalid."),
    (ExternalWidgetStartupFailureReason.unreadableStorage, "External widget storage could not be read safely."),
    (ExternalWidgetStartupFailureReason.registrationConflict, "External widgets could not be registered because of a widget registration conflict."),
    (ExternalWidgetStartupFailureReason.unknown, "External widgets could not be loaded safely."),
])
func unavailableExternalWidgetPresentationUsesOnlyCoarseReason(
    reason: ExternalWidgetStartupFailureReason,
    expectedDetail: String
) {
    let presentation = ExternalWidgetStartupHealth
        .unavailable(reason)
        .settingsPresentation

    #expect(presentation.status == "Unavailable")
    #expect(presentation.detail == expectedDetail)
    #expect(presentation.systemImage == "exclamationmark.triangle")
}

import SchneeBarCore
import Testing
@testable import SchneeBar

private actor WidgetRuntimePersistenceStore: WidgetPreferencesStore {
    private var saved: [WidgetConfiguration] = []

    func load() async throws -> WidgetConfiguration {
        WidgetConfiguration()
    }

    func save(_ configuration: WidgetConfiguration) async throws {
        saved.append(configuration)
    }

    func savedConfigurations() -> [WidgetConfiguration] {
        saved
    }
}

@Test @MainActor
func widgetRuntimeFlushPersistsLatestConfigurationImmediately() async throws {
    let store = WidgetRuntimePersistenceStore()
    let model = WidgetRuntimeModel(preferencesStore: store)
    let descriptor = WidgetDescriptor(
        id: "system.persistence_test",
        displayName: "Persistence Test"
    )

    model.setEnabled(false, for: descriptor)
    model.setRepresentation(.compact, for: descriptor)

    await model.flushPreferences()

    let savedAfterFlush = await store.savedConfigurations()
    #expect(savedAfterFlush.count == 1)
    #expect(savedAfterFlush.first == model.configuration)
    #expect(
        savedAfterFlush.first?
            .preference(for: descriptor.id)?
            .isEnabled == false
    )
    #expect(
        savedAfterFlush.first?
            .preference(for: descriptor.id)?
            .representation == .compact
    )

    try await Task.sleep(for: .milliseconds(250))

    let savedAfterDebounceWindow = await store.savedConfigurations()
    #expect(savedAfterDebounceWindow == savedAfterFlush)
}

@Test @MainActor
func widgetRuntimeFlushWithoutPendingChangeStillPersistsCurrentState() async {
    let store = WidgetRuntimePersistenceStore()
    let model = WidgetRuntimeModel(preferencesStore: store)

    await model.flushPreferences()

    let saved = await store.savedConfigurations()
    #expect(saved == [WidgetConfiguration()])
}

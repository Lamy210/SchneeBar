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

private actor BlockingWidgetRuntimePersistenceStore: WidgetPreferencesStore {
    private var saved: [WidgetConfiguration] = []
    private var firstSaveStarted = false
    private var firstSaveStartedWaiters: [CheckedContinuation<Void, Never>] = []
    private var firstSaveReleaseContinuation: CheckedContinuation<Void, Never>?

    func load() async throws -> WidgetConfiguration {
        WidgetConfiguration()
    }

    func save(_ configuration: WidgetConfiguration) async throws {
        if !firstSaveStarted {
            firstSaveStarted = true
            let waiters = firstSaveStartedWaiters
            firstSaveStartedWaiters.removeAll()
            for waiter in waiters {
                waiter.resume()
            }

            await withCheckedContinuation { continuation in
                firstSaveReleaseContinuation = continuation
            }
        }

        saved.append(configuration)
    }

    func waitForFirstSaveToStart() async {
        if firstSaveStarted {
            return
        }

        await withCheckedContinuation { continuation in
            firstSaveStartedWaiters.append(continuation)
        }
    }

    func releaseFirstSave() {
        firstSaveReleaseContinuation?.resume()
        firstSaveReleaseContinuation = nil
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
func widgetRuntimeFlushWaitsForOlderSaveBeforeFinalWrite() async throws {
    let store = BlockingWidgetRuntimePersistenceStore()
    let model = WidgetRuntimeModel(preferencesStore: store)
    let descriptor = WidgetDescriptor(
        id: "system.persistence_race_test",
        displayName: "Persistence Race Test"
    )

    model.setEnabled(false, for: descriptor)
    await store.waitForFirstSaveToStart()

    model.setRepresentation(.compact, for: descriptor)

    let flushTask = Task { @MainActor in
        await model.flushPreferences()
    }
    await Task.yield()

    await store.releaseFirstSave()
    await flushTask.value

    let saved = await store.savedConfigurations()
    #expect(saved.count == 2)
    #expect(
        saved.first?
            .preference(for: descriptor.id)?
            .isEnabled == false
    )
    #expect(
        saved.first?
            .preference(for: descriptor.id)?
            .representation == nil
    )
    #expect(saved.last == model.configuration)
    #expect(
        saved.last?
            .preference(for: descriptor.id)?
            .representation == .compact
    )

    try await Task.sleep(for: .milliseconds(250))
    #expect(await store.savedConfigurations() == saved)
}

@Test @MainActor
func widgetRuntimeFlushWithoutPendingChangeStillPersistsCurrentState() async {
    let store = WidgetRuntimePersistenceStore()
    let model = WidgetRuntimeModel(preferencesStore: store)

    await model.flushPreferences()

    let saved = await store.savedConfigurations()
    #expect(saved == [WidgetConfiguration()])
}

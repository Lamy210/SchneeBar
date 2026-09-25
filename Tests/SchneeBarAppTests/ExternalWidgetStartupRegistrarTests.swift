import Foundation
import SchneeBarCore
import SchneeBarExternalWidgets
import Testing
@testable import SchneeBar

private struct StartupNativeWidgetProvider: WidgetProvider {
    let descriptor = WidgetDescriptor(
        id: "system.clock",
        displayName: "Clock",
        refreshPolicy: .manual
    )

    func snapshot() async throws -> WidgetSnapshot {
        WidgetSnapshot(
            descriptor: descriptor,
            generatedAt: Date(timeIntervalSince1970: 100),
            severity: .nominal,
            priority: .normal,
            representations: .init(
                compact: .init(
                    text: "native",
                    accessibilityLabel: "native"
                ),
                normal: .init(
                    text: "native",
                    accessibilityLabel: "native"
                )
            )
        )
    }
}

private enum StartupRegistrationTestError: Error, Equatable {
    case loadFailed
}

@Test
func startupRegistrationKeepsExternalWidgetsDisabledWithoutUserPreference() async throws {
    let definition = startupExternalWidgetDefinition(
        id: "external.acme.build"
    )
    let registrar = ExternalWidgetStartupRegistrar(
        loadDefinitions: { [definition] }
    )
    let engine = WidgetEngine(
        providers: [StartupNativeWidgetProvider()]
    )

    try await registrar.loadAndRegister(in: engine)

    let descriptors = await engine.descriptors()
    let externalDescriptor = try #require(
        descriptors.first(where: {
            $0.id == definition.descriptor.id
        })
    )
    #expect(!externalDescriptor.defaultIsEnabled)
    #expect(externalDescriptor.refreshPolicy == .manual)

    _ = await engine.refreshDue()
    #expect(await engine.snapshot(id: definition.descriptor.id) == nil)
}

@Test
func startupRegistrationForcesDisabledDefaultEvenForPrebuiltDefinition() async throws {
    let id: WidgetID = "external.untrusted.build"
    let sourceDescriptor = WidgetDescriptor(
        id: id,
        displayName: "Untrusted Build",
        defaultIsEnabled: true,
        defaultOrder: 1_200,
        refreshPolicy: .interval(5)
    )
    let definition = ExternalWidgetDefinition(
        descriptor: sourceDescriptor,
        snapshot: WidgetSnapshot(
            descriptor: sourceDescriptor,
            generatedAt: Date(timeIntervalSince1970: 123),
            severity: .nominal,
            priority: .normal,
            representations: .init(
                compact: .init(
                    text: "OK",
                    accessibilityLabel: "Build okay"
                ),
                normal: .init(
                    text: "Build okay",
                    accessibilityLabel: "Build okay"
                )
            )
        )
    )
    let engine = WidgetEngine()

    try await ExternalWidgetStartupRegistrar(
        loadDefinitions: { [definition] }
    ).loadAndRegister(in: engine)

    let descriptors = await engine.descriptors()
    let descriptor = try #require(descriptors.first)
    #expect(!descriptor.defaultIsEnabled)
    #expect(descriptor.refreshPolicy == .manual)

    _ = await engine.refreshDue()
    #expect(await engine.snapshot(id: id) == nil)
}

@Test
func startupRegistrationHonorsExistingExplicitEnablePreference() async throws {
    let definition = startupExternalWidgetDefinition(
        id: "external.acme.build"
    )
    let registrar = ExternalWidgetStartupRegistrar(
        loadDefinitions: { [definition] }
    )
    let engine = WidgetEngine()

    try await registrar.loadAndRegister(in: engine)
    let descriptors = await engine.descriptors()
    let descriptor = try #require(descriptors.first)
    await engine.setConfiguration(
        WidgetConfiguration(
            preferences: [
                WidgetPreference(
                    id: descriptor.id,
                    isEnabled: true,
                    order: descriptor.defaultOrder
                ),
            ]
        )
    )

    _ = await engine.refreshDue(
        at: Date(timeIntervalSince1970: 1_000)
    )

    #expect(
        await engine.snapshot(id: descriptor.id)?
            .content().text == "Build okay"
    )
    #expect(
        await engine.secondsUntilNextRefresh(
            at: Date(timeIntervalSince1970: 1_001),
            maximum: 30
        ) == 30
    )
}

@Test
func startupRegistrationCannotOverwriteNativeProviderID() async throws {
    let nativeID: WidgetID = "system.clock"
    let sourceDescriptor = WidgetDescriptor(
        id: nativeID,
        displayName: "External Clock",
        defaultIsEnabled: false,
        defaultOrder: 1_200,
        refreshPolicy: .manual
    )
    let definition = ExternalWidgetDefinition(
        descriptor: sourceDescriptor,
        snapshot: WidgetSnapshot(
            descriptor: sourceDescriptor,
            generatedAt: Date(timeIntervalSince1970: 123),
            severity: .nominal,
            priority: .normal,
            representations: .init(
                compact: .init(
                    text: "external",
                    accessibilityLabel: "external"
                ),
                normal: .init(
                    text: "external",
                    accessibilityLabel: "external"
                )
            )
        )
    )
    let engine = WidgetEngine(
        providers: [StartupNativeWidgetProvider()]
    )

    await #expect(
        throws: WidgetProviderBatchUpdateError
            .providerAlreadyRegistered(nativeID)
    ) {
        try await ExternalWidgetStartupRegistrar(
            loadDefinitions: { [definition] }
        ).loadAndRegister(in: engine)
    }

    #expect(await engine.descriptors().map(\.id) == [nativeID])
    _ = await engine.refresh(id: nativeID)
    #expect(await engine.snapshot(id: nativeID)?.content().text == "native")
}

@Test
func startupLoaderFailureLeavesPreviouslyRegisteredGroupUntouched() async throws {
    let oldDefinition = startupExternalWidgetDefinition(
        id: "external.old.build"
    )
    let oldRegistrar = ExternalWidgetStartupRegistrar(
        loadDefinitions: { [oldDefinition] }
    )
    let engine = WidgetEngine()

    try await oldRegistrar.loadAndRegister(in: engine)

    let failingRegistrar = ExternalWidgetStartupRegistrar(
        loadDefinitions: {
            throw StartupRegistrationTestError.loadFailed
        }
    )

    await #expect(throws: StartupRegistrationTestError.loadFailed) {
        try await failingRegistrar.loadAndRegister(in: engine)
    }

    #expect(
        await engine.descriptors().map(\.id)
            == [oldDefinition.descriptor.id]
    )
}

@Test
func startupCancellationDoesNotReplacePreviouslyRegisteredGroup() async throws {
    let oldDefinition = startupExternalWidgetDefinition(
        id: "external.old.build"
    )
    let newDefinition = startupExternalWidgetDefinition(
        id: "external.new.build"
    )
    let oldRegistrar = ExternalWidgetStartupRegistrar(
        loadDefinitions: { [oldDefinition] }
    )
    let engine = WidgetEngine()

    try await oldRegistrar.loadAndRegister(in: engine)

    let cancelledRegistrar = ExternalWidgetStartupRegistrar(
        loadDefinitions: {
            withUnsafeCurrentTask { task in
                task?.cancel()
            }
            try Task.checkCancellation()
            return [newDefinition]
        }
    )

    await #expect(throws: CancellationError.self) {
        try await cancelledRegistrar.loadAndRegister(in: engine)
    }

    #expect(
        await engine.descriptors().map(\.id)
            == [oldDefinition.descriptor.id]
    )
}

@Test
func stablePreferenceSurvivesTemporaryExternalWidgetAbsence() async throws {
    let definition = startupExternalWidgetDefinition(
        id: "external.acme.build"
    )
    let preference = WidgetPreference(
        id: definition.descriptor.id,
        isEnabled: true,
        order: 1_234
    )
    let engine = WidgetEngine(
        configuration: WidgetConfiguration(
            preferences: [preference]
        )
    )

    try await ExternalWidgetStartupRegistrar(
        loadDefinitions: { [definition] }
    ).loadAndRegister(in: engine)
    _ = await engine.refreshDue(
        at: Date(timeIntervalSince1970: 1_000)
    )
    #expect(
        await engine.snapshot(id: definition.descriptor.id) != nil
    )

    try await ExternalWidgetStartupRegistrar(
        loadDefinitions: { [] }
    ).loadAndRegister(in: engine)
    #expect((await engine.descriptors()).isEmpty)
    #expect(
        await engine.currentConfiguration()
            .preference(for: definition.descriptor.id)
            == preference
    )

    try await ExternalWidgetStartupRegistrar(
        loadDefinitions: { [definition] }
    ).loadAndRegister(in: engine)
    _ = await engine.refreshDue(
        at: Date(timeIntervalSince1970: 2_000)
    )

    #expect(
        await engine.snapshot(id: definition.descriptor.id)?
            .content().text == "Build okay"
    )
    #expect(
        await engine.currentConfiguration()
            .preference(for: definition.descriptor.id)
            == preference
    )
}

@Test
func successfulStartupReplacementRemovesDocumentsNoLongerPresent() async throws {
    let oldDefinition = startupExternalWidgetDefinition(
        id: "external.old.build"
    )
    let newDefinition = startupExternalWidgetDefinition(
        id: "external.new.build"
    )
    let engine = WidgetEngine()

    try await ExternalWidgetStartupRegistrar(
        loadDefinitions: { [oldDefinition] }
    ).loadAndRegister(in: engine)

    try await ExternalWidgetStartupRegistrar(
        loadDefinitions: { [newDefinition] }
    ).loadAndRegister(in: engine)

    #expect(
        await engine.descriptors().map(\.id)
            == [newDefinition.descriptor.id]
    )
}

private func startupExternalWidgetDefinition(
    id: WidgetID
) -> ExternalWidgetDefinition {
    let descriptor = WidgetDescriptor(
        id: id,
        displayName: "External Build",
        defaultIsEnabled: false,
        defaultOrder: 1_200,
        defaultRepresentation: .normal,
        visibilityPolicy: .always,
        refreshPolicy: .adaptive(
            active: 5,
            idle: 300
        )
    )
    return ExternalWidgetDefinition(
        descriptor: descriptor,
        snapshot: WidgetSnapshot(
            descriptor: descriptor,
            generatedAt: Date(timeIntervalSince1970: 123),
            severity: .nominal,
            priority: .normal,
            representations: .init(
                compact: .init(
                    text: "OK",
                    accessibilityLabel: "Build okay"
                ),
                normal: .init(
                    text: "Build okay",
                    accessibilityLabel: "Build okay"
                )
            )
        )
    )
}

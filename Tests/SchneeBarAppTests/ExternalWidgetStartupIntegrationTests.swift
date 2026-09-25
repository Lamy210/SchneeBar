import Foundation
import SchneeBarCore
@testable import SchneeBarExternalWidgets
import Testing
@testable import SchneeBar

@Test
func filesystemCollectionRegistersThroughStartupComposition() async throws {
    let fixture = try StartupIntegrationFixture()
    defer { fixture.cleanup() }

    try fixture.writeValidDocument(
        id: "external.integration.build",
        named: "build.json"
    )

    let loader = ExternalWidgetDirectoryLoader(rootURL: fixture.rootURL)
    let registrar = ExternalWidgetStartupRegistrar(
        loadDefinitions: {
            try await loader.load(
                now: Date(timeIntervalSince1970: 1_800_000_000)
            )
        },
        classifyFailure: ExternalWidgetStartupRegistrar.classifyStartupFailure
    )
    let engine = WidgetEngine()

    let result = try await registrar.loadAndRegister(in: engine)

    #expect(result == .loaded(widgetCount: 1))
    let descriptors = await engine.descriptors()
    let descriptor = try #require(descriptors.first)
    #expect(descriptor.id == "external.integration.build")
    #expect(!descriptor.defaultIsEnabled)
    #expect(descriptor.refreshPolicy == .manual)

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
    _ = await engine.refresh(id: descriptor.id)

    #expect(
        await engine.snapshot(id: descriptor.id)?
            .content(.normal).text == "Integration build okay"
    )
}

@Test
func malformedFilesystemReloadKeepsLastKnownGoodExternalGroup() async throws {
    let fixture = try StartupIntegrationFixture()
    defer { fixture.cleanup() }

    let id: WidgetID = "external.integration.build"
    try fixture.writeValidDocument(
        id: id.rawValue,
        named: "build.json"
    )

    let loader = ExternalWidgetDirectoryLoader(rootURL: fixture.rootURL)
    let registrar = ExternalWidgetStartupRegistrar(
        loadDefinitions: {
            try await loader.load(
                now: Date(timeIntervalSince1970: 1_800_000_000)
            )
        },
        classifyFailure: ExternalWidgetStartupRegistrar.classifyStartupFailure
    )
    let engine = WidgetEngine()

    let initialResult = try await registrar.loadAndRegister(in: engine)
    #expect(initialResult == .loaded(widgetCount: 1))

    try Data("{".utf8).write(
        to: fixture.rootURL.appendingPathComponent("build.json"),
        options: .atomic
    )

    let failedResult = try await registrar.loadAndRegister(in: engine)

    #expect(failedResult == .unavailable(.invalidDocuments))
    #expect(await engine.descriptors().map(\.id) == [id])

    _ = await engine.refresh(id: id)
    #expect(
        await engine.snapshot(id: id)?
            .content(.normal).text == "Integration build okay"
    )
}

private struct StartupIntegrationFixture {
    let baseURL: URL
    let rootURL: URL

    init() throws {
        baseURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "SchneeBarStartupIntegration-\(UUID().uuidString)",
                isDirectory: true
            )
        rootURL = baseURL.appendingPathComponent(
            "ExternalWidgets",
            isDirectory: true
        )

        try FileManager.default.createDirectory(
            at: rootURL,
            withIntermediateDirectories: true
        )
    }

    func writeValidDocument(
        id: String,
        named name: String
    ) throws {
        let document = ExternalWidgetDocument(
            schemaVersion: 1,
            id: id,
            displayName: "Integration Build",
            defaultEnabled: false,
            defaultOrder: 1_200,
            defaultRepresentation: .normal,
            visibility: ExternalWidgetVisibilityDocument(
                kind: .always
            ),
            refresh: ExternalWidgetRefreshDocument(
                kind: .manual
            ),
            snapshot: ExternalWidgetSnapshotDocument(
                severity: .nominal,
                priority: .normal,
                compact: ExternalWidgetContentDocument(
                    text: "OK",
                    systemImage: "checkmark.circle.fill",
                    accessibilityLabel: "Integration build okay"
                ),
                normal: ExternalWidgetContentDocument(
                    text: "Integration build okay",
                    systemImage: "hammer",
                    accessibilityLabel: "Integration build okay"
                )
            )
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(document)
        try data.write(
            to: rootURL.appendingPathComponent(name),
            options: .atomic
        )
    }

    func cleanup() {
        try? FileManager.default.removeItem(at: baseURL)
    }
}

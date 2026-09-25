import SchneeBarCore
import SchneeBarExternalWidgets

struct ExternalWidgetStartupRegistrar: Sendable {
    static let providerGroupID = WidgetProviderGroupID(
        rawValue: "external.widgets"
    )

    typealias LoadDefinitions = @Sendable () async throws
        -> [ExternalWidgetDefinition]

    private let loadDefinitions: LoadDefinitions

    init(
        loadDefinitions: @escaping LoadDefinitions
    ) {
        self.loadDefinitions = loadDefinitions
    }

    static func applicationSupport() -> Self {
        let loader = ExternalWidgetDirectoryLoader()
        return Self(
            loadDefinitions: {
                try await loader.load()
            }
        )
    }

    func loadAndRegister(
        in engine: WidgetEngine
    ) async throws {
        let definitions = try await loadDefinitions()
        try Task.checkCancellation()

        let providers: [any WidgetProvider] = definitions.map {
            StaticExternalWidgetProvider(definition: $0)
        }

        try await engine.replaceProviders(
            in: Self.providerGroupID,
            with: providers
        )
    }
}

private struct StaticExternalWidgetProvider: WidgetProvider {
    let descriptor: WidgetDescriptor
    private let storedSnapshot: WidgetSnapshot

    init(definition: ExternalWidgetDefinition) {
        let source = definition.descriptor
        descriptor = WidgetDescriptor(
            id: source.id,
            displayName: source.displayName,
            defaultIsEnabled: false,
            defaultOrder: source.defaultOrder,
            defaultRepresentation: source.defaultRepresentation,
            visibilityPolicy: source.visibilityPolicy,
            refreshPolicy: .manual
        )

        storedSnapshot = WidgetSnapshot(
            descriptor: descriptor,
            generatedAt: definition.snapshot.generatedAt,
            severity: definition.snapshot.severity,
            priority: definition.snapshot.priority,
            representations: definition.snapshot.representations
        )
    }

    func snapshot() async throws -> WidgetSnapshot {
        storedSnapshot
    }
}

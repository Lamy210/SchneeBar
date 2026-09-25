import SchneeBarCore
import SchneeBarExternalWidgets

struct ExternalWidgetStartupRegistrar: Sendable {
    static let providerGroupID = WidgetProviderGroupID(
        rawValue: "external.widgets"
    )

    typealias LoadDefinitions = @Sendable () async throws
        -> [ExternalWidgetDefinition]
    typealias ClassifyFailure = @Sendable (any Error)
        -> ExternalWidgetStartupFailureReason

    private let loadDefinitions: LoadDefinitions
    private let classifyFailure: ClassifyFailure

    init(
        loadDefinitions: @escaping LoadDefinitions,
        classifyFailure: @escaping ClassifyFailure = { _ in .unknown }
    ) {
        self.loadDefinitions = loadDefinitions
        self.classifyFailure = classifyFailure
    }

    static func applicationSupport() -> Self {
        let loader = ExternalWidgetDirectoryLoader()
        return Self(
            loadDefinitions: {
                try await loader.load()
            },
            classifyFailure: Self.classifyStartupFailure
        )
    }

    func loadAndRegister(
        in engine: WidgetEngine
    ) async throws -> ExternalWidgetStartupRegistrationResult {
        let definitions: [ExternalWidgetDefinition]
        do {
            definitions = try await loadDefinitions()
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            return .unavailable(classifyFailure(error))
        }

        try Task.checkCancellation()

        let providers: [any WidgetProvider] = definitions.map {
            StaticExternalWidgetProvider(definition: $0)
        }

        do {
            try await engine.replaceProviders(
                in: Self.providerGroupID,
                with: providers
            )
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            return .unavailable(classifyFailure(error))
        }

        return .loaded(widgetCount: definitions.count)
    }

    static func classifyStartupFailure(
        _ error: any Error
    ) -> ExternalWidgetStartupFailureReason {
        if let loaderError = error as? ExternalWidgetDirectoryLoaderError {
            switch loaderError {
            case .unsafeRoot, .invalidFilename, .unsafeDocumentEntry:
                return .unsafeStorage

            case .tooManyDirectoryEntries,
                 .tooManyDocuments,
                 .documentTooLarge,
                 .aggregateTooLarge:
                return .resourceLimit

            case .invalidDocument:
                return .invalidDocuments

            case .rootUnavailable, .unreadableDocument:
                return .unreadableStorage
            }
        }

        if error is WidgetProviderBatchUpdateError {
            return .registrationConflict
        }

        return .unknown
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

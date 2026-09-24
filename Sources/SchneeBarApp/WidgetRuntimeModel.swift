import Observation
import SchneeBarCore

@MainActor
@Observable
final class WidgetRuntimeModel {
    var snapshots: [WidgetSnapshot] = []
    var descriptors: [WidgetDescriptor] = []
    var configuration = WidgetConfiguration()
    var externalWidgetStartupHealth: ExternalWidgetStartupHealth = .notAttempted

    @ObservationIgnored
    private let preferencesStore: any WidgetPreferencesStore

    @ObservationIgnored
    private var persistenceTask: Task<Void, Never>?

    @ObservationIgnored
    var onConfigurationChanged: ((WidgetConfiguration) -> Void)?

    init(preferencesStore: any WidgetPreferencesStore) {
        self.preferencesStore = preferencesStore
    }

    var orderedDescriptors: [WidgetDescriptor] {
        descriptors.sorted { lhs, rhs in
            let lhsOrder = configuration.order(for: lhs)
            let rhsOrder = configuration.order(for: rhs)
            if lhsOrder != rhsOrder {
                return lhsOrder < rhsOrder
            }
            return lhs.id.rawValue < rhs.id.rawValue
        }
    }

    func loadPreferences() async {
        do {
            configuration = try await preferencesStore.load()
        } catch {
            configuration = WidgetConfiguration()
        }
    }

    func setEnabled(_ isEnabled: Bool, for descriptor: WidgetDescriptor) {
        configuration.setEnabled(isEnabled, for: descriptor)
        configurationDidChange()
    }

    func setRepresentation(
        _ representation: WidgetRepresentationKind?,
        for descriptor: WidgetDescriptor
    ) {
        configuration.setRepresentation(representation, for: descriptor)
        configurationDidChange()
    }

    func moveWidget(id: WidgetID, offset: Int) {
        guard offset != 0 else { return }

        let ordered = orderedDescriptors
        guard let sourceIndex = ordered.firstIndex(where: { $0.id == id }) else { return }

        let destinationIndex = sourceIndex + offset
        guard ordered.indices.contains(destinationIndex) else { return }

        var reordered = ordered
        let moved = reordered.remove(at: sourceIndex)
        reordered.insert(moved, at: destinationIndex)

        for (index, descriptor) in reordered.enumerated() {
            configuration.setOrder(index * 100, for: descriptor)
        }

        configurationDidChange()
    }

    private func configurationDidChange() {
        let latestConfiguration = configuration
        onConfigurationChanged?(latestConfiguration)

        persistenceTask?.cancel()
        let store = preferencesStore
        persistenceTask = Task {
            do {
                try await Task.sleep(for: .milliseconds(150))
                try Task.checkCancellation()
                try await store.save(latestConfiguration)
            } catch is CancellationError {
                return
            } catch {
                // Persistence diagnostics will be surfaced in a later phase.
            }
        }
    }
}

import Observation
import SchneeBarCore

@MainActor
@Observable
final class ActivityRuntimeModel {
    typealias DetailLoader = @MainActor @Sendable (ActivityItem) async throws -> ActivityDetailSnapshot

    var items: [ActivityItem] = []
    var selectedItem: ActivityItem?
    var detail: ActivityDetailSnapshot?
    var detailIsLoading = false
    var detailErrorMessage: String?

    @ObservationIgnored
    private var detailLoader: DetailLoader?

    @ObservationIgnored
    private var detailTask: Task<Void, Never>?

    func configureDetailLoader(_ loader: @escaping DetailLoader) {
        detailLoader = loader
    }

    func replace(with items: [ActivityItem]) {
        self.items = items

        guard let selectedItem else { return }
        guard let refreshed = items.first(where: { $0.id == selectedItem.id }) else {
            dismissDetail()
            return
        }
        self.selectedItem = refreshed
    }

    func requestDetail(for item: ActivityItem) {
        selectedItem = item
        detail = nil
        detailErrorMessage = nil
        detailIsLoading = true
        loadSelectedDetail()
    }

    func retryDetail() {
        guard selectedItem != nil else { return }
        detailErrorMessage = nil
        detailIsLoading = true
        loadSelectedDetail()
    }

    func dismissDetail() {
        detailTask?.cancel()
        detailTask = nil
        selectedItem = nil
        detail = nil
        detailErrorMessage = nil
        detailIsLoading = false
    }

    private func loadSelectedDetail() {
        detailTask?.cancel()
        guard let item = selectedItem,
              let detailLoader
        else {
            detailIsLoading = false
            detailErrorMessage = "Job details are unavailable for this activity."
            return
        }

        detailTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let loaded = try await detailLoader(item)
                try Task.checkCancellation()
                guard selectedItem?.id == item.id else { return }
                detail = loaded
                detailErrorMessage = nil
                detailIsLoading = false
            } catch is CancellationError {
                return
            } catch {
                guard selectedItem?.id == item.id else { return }
                detail = nil
                detailErrorMessage = "Could not load workflow job details."
                detailIsLoading = false
            }
        }
    }
}

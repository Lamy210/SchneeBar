import Observation
import SchneeBarCore

@MainActor
@Observable
final class ActivityRuntimeModel {
    typealias DetailLoader = @MainActor @Sendable (ActivityItem) async throws -> ActivityDetailSnapshot
    typealias DeliveryHistoryLoader = @MainActor @Sendable (ActivityItem) async throws -> DeliveryHistorySnapshot

    var items: [ActivityItem] = []
    var selectedItem: ActivityItem?
    var detail: ActivityDetailSnapshot?
    var detailIsLoading = false
    var detailErrorMessage: String?
    var deliveryHistory: DeliveryHistorySnapshot?
    var deliveryHistoryIsLoading = false
    var deliveryHistoryErrorMessage: String?
    var isPresentingDeliveryHistory = false

    @ObservationIgnored
    private var detailLoader: DetailLoader?

    @ObservationIgnored
    private var deliveryHistoryLoader: DeliveryHistoryLoader?

    @ObservationIgnored
    private var detailTask: Task<Void, Never>?

    @ObservationIgnored
    private var deliveryHistoryTask: Task<Void, Never>?

    func configureDetailLoader(_ loader: @escaping DetailLoader) {
        detailLoader = loader
    }

    func configureDeliveryHistoryLoader(
        _ loader: @escaping DeliveryHistoryLoader
    ) {
        deliveryHistoryLoader = loader
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

    func requestDeliveryHistory() {
        guard selectedItem != nil, detail != nil else { return }
        isPresentingDeliveryHistory = true
        deliveryHistory = nil
        deliveryHistoryErrorMessage = nil
        deliveryHistoryIsLoading = true
        loadSelectedDeliveryHistory()
    }

    func retryDeliveryHistory() {
        guard isPresentingDeliveryHistory, selectedItem != nil else { return }
        deliveryHistoryErrorMessage = nil
        deliveryHistoryIsLoading = true
        loadSelectedDeliveryHistory()
    }

    func dismissDeliveryHistory() {
        deliveryHistoryTask?.cancel()
        deliveryHistoryTask = nil
        isPresentingDeliveryHistory = false
        deliveryHistory = nil
        deliveryHistoryErrorMessage = nil
        deliveryHistoryIsLoading = false
    }

    func dismissDetail() {
        detailTask?.cancel()
        detailTask = nil
        deliveryHistoryTask?.cancel()
        deliveryHistoryTask = nil
        selectedItem = nil
        detail = nil
        detailErrorMessage = nil
        detailIsLoading = false
        isPresentingDeliveryHistory = false
        deliveryHistory = nil
        deliveryHistoryErrorMessage = nil
        deliveryHistoryIsLoading = false
    }

    private func loadSelectedDeliveryHistory() {
        deliveryHistoryTask?.cancel()
        guard let item = selectedItem,
              let deliveryHistoryLoader
        else {
            deliveryHistoryIsLoading = false
            deliveryHistoryErrorMessage = "Delivery history is unavailable for this activity."
            return
        }

        deliveryHistoryTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let loaded = try await deliveryHistoryLoader(item)
                try Task.checkCancellation()
                guard isPresentingDeliveryHistory,
                      selectedItem?.id == item.id
                else {
                    return
                }
                deliveryHistory = loaded
                deliveryHistoryErrorMessage = nil
                deliveryHistoryIsLoading = false
            } catch is CancellationError {
                return
            } catch {
                guard isPresentingDeliveryHistory,
                      selectedItem?.id == item.id
                else {
                    return
                }
                deliveryHistory = nil
                deliveryHistoryErrorMessage = "Could not load delivery history."
                deliveryHistoryIsLoading = false
            }
        }
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

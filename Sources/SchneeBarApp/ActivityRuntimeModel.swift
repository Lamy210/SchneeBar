import Observation
import SchneeBarCore

@MainActor
@Observable
final class ActivityRuntimeModel {
    typealias DetailLoader = @MainActor @Sendable (ActivityItem) async throws -> ActivityDetailSnapshot
    typealias DeliveryHistoryLoader = @MainActor @Sendable (ActivityItem) async throws -> DeliveryHistorySnapshot
    typealias DetailActionPerformer =
        @MainActor @Sendable (ActivityItem, ActivityDetailAction) async throws -> Void

    var items: [ActivityItem] = []
    var selectedItem: ActivityItem?
    var detail: ActivityDetailSnapshot?
    var detailIsLoading = false
    var detailErrorMessage: String?
    var deliveryHistory: DeliveryHistorySnapshot?
    var deliveryHistoryIsLoading = false
    var deliveryHistoryErrorMessage: String?
    var isPresentingDeliveryHistory = false
    var detailActionIsRunning = false
    var detailActionErrorMessage: String?

    @ObservationIgnored
    private var detailLoader: DetailLoader?

    @ObservationIgnored
    private var deliveryHistoryLoader: DeliveryHistoryLoader?

    @ObservationIgnored
    private var detailActionPerformer: DetailActionPerformer?

    @ObservationIgnored
    private var detailTask: Task<Void, Never>?

    @ObservationIgnored
    private var detailActionTask: Task<Void, Never>?

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

    func configureDetailActionPerformer(
        _ performer: @escaping DetailActionPerformer
    ) {
        detailActionPerformer = performer
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
        detailActionErrorMessage = nil
        detailIsLoading = true
        loadSelectedDetail()
    }

    func retryDetail() {
        guard selectedItem != nil else { return }
        detailErrorMessage = nil
        detailIsLoading = true
        loadSelectedDetail()
    }

    func performDetailAction(_ action: ActivityDetailAction) {
        guard !detailActionIsRunning,
              let item = selectedItem,
              let detail,
              detail.actions.contains(action),
              let detailActionPerformer
        else {
            return
        }

        detailActionTask?.cancel()
        detailActionErrorMessage = nil
        detailActionIsRunning = true

        detailActionTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                try await detailActionPerformer(item, action)
                try Task.checkCancellation()
                guard selectedItem?.id == item.id else { return }

                detailActionIsRunning = false
                detailActionErrorMessage = nil
                retryDetail()
            } catch is CancellationError {
                guard selectedItem?.id == item.id else { return }
                detailActionIsRunning = false
            } catch {
                guard selectedItem?.id == item.id else { return }
                detailActionIsRunning = false
                detailActionErrorMessage = Self.actionErrorMessage(
                    for: action
                )
            }
        }
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
        detailActionTask?.cancel()
        detailActionTask = nil
        deliveryHistoryTask?.cancel()
        deliveryHistoryTask = nil
        selectedItem = nil
        detail = nil
        detailErrorMessage = nil
        detailIsLoading = false
        detailActionIsRunning = false
        detailActionErrorMessage = nil
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

    private static func actionErrorMessage(
        for action: ActivityDetailAction
    ) -> String {
        switch action {
        case .rerunWorkflow:
            "Could not re-run workflow."
        case .cancelWorkflow:
            "Could not cancel workflow."
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

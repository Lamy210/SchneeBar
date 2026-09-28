import Observation
import SchneeBarCore

@MainActor
@Observable
final class ActivityRuntimeModel {
    typealias DetailLoader = @MainActor @Sendable (ActivityItem) async throws -> ActivityDetailSnapshot
    typealias DeliveryHistoryLoader = @MainActor @Sendable (ActivityItem) async throws -> DeliveryHistorySnapshot
    typealias DetailActionHandler = @MainActor @Sendable (
        ActivityItem,
        ActivityDetailAction
    ) async throws -> Void

    var items: [ActivityItem] = []
    var isTruncated = false
    var selectedItem: ActivityItem?
    var detail: ActivityDetailSnapshot?
    var detailIsLoading = false
    var detailErrorMessage: String?
    var deliveryHistory: DeliveryHistorySnapshot?
    var deliveryHistoryIsLoading = false
    var deliveryHistoryErrorMessage: String?
    var isPresentingDeliveryHistory = false
    var isPresentingHistoryEntryDetail = false
    var detailActionInProgress: ActivityDetailAction?
    var detailActionErrorMessage: String?

    @ObservationIgnored
    private var detailLoader: DetailLoader?

    @ObservationIgnored
    private var deliveryHistoryLoader: DeliveryHistoryLoader?

    @ObservationIgnored
    private var detailActionHandler: DetailActionHandler?

    @ObservationIgnored
    private var detailTask: Task<Void, Never>?

    @ObservationIgnored
    private var detailActionTask: Task<Void, Never>?

    @ObservationIgnored
    private var deliveryHistoryTask: Task<Void, Never>?

    @ObservationIgnored
    private var deliveryHistoryParentItem: ActivityItem?

    @ObservationIgnored
    private var deliveryHistoryParentDetail: ActivityDetailSnapshot?

    func configureDetailLoader(_ loader: @escaping DetailLoader) {
        detailLoader = loader
    }

    func configureDeliveryHistoryLoader(
        _ loader: @escaping DeliveryHistoryLoader
    ) {
        deliveryHistoryLoader = loader
    }

    func configureDetailActionHandler(
        _ handler: @escaping DetailActionHandler
    ) {
        detailActionHandler = handler
    }

    func replace(
        with items: [ActivityItem],
        isTruncated: Bool = false
    ) {
        self.items = items
        self.isTruncated = isTruncated

        if isPresentingHistoryEntryDetail {
            if let parentItem = deliveryHistoryParentItem,
               let refreshedParent = items.first(where: {
                   $0.id == parentItem.id
               })
            {
                deliveryHistoryParentItem = refreshedParent
            }
            return
        }

        guard let selectedItem else { return }
        guard let refreshed = items.first(where: { $0.id == selectedItem.id }) else {
            dismissDetail()
            return
        }
        self.selectedItem = refreshed
    }

    func requestDetail(for item: ActivityItem) {
        detailActionTask?.cancel()
        detailActionTask = nil
        clearHistoryEntryDetailNavigation()
        selectedItem = item
        detail = nil
        detailErrorMessage = nil
        detailActionErrorMessage = nil
        detailActionInProgress = nil
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
        guard detailActionInProgress == nil,
              let item = selectedItem,
              let detail,
              detail.actions.contains(action),
              let detailActionHandler
        else {
            return
        }

        detailActionTask?.cancel()
        detailActionErrorMessage = nil
        detailActionInProgress = action

        detailActionTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                try await detailActionHandler(item, action)
                try Task.checkCancellation()
                guard selectedItem?.id == item.id else { return }
                detailActionInProgress = nil
                detailActionErrorMessage = nil
                detailIsLoading = true
                loadSelectedDetail()
            } catch is CancellationError {
                if selectedItem?.id == item.id {
                    detailActionInProgress = nil
                }
                return
            } catch {
                guard selectedItem?.id == item.id else { return }
                detailActionInProgress = nil
                detailActionErrorMessage = detailActionFailureMessage(for: action)
            }
        }
    }

    func requestDeliveryHistory() {
        guard selectedItem != nil,
              detail != nil,
              detailActionInProgress == nil
        else {
            return
        }
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

    func requestDetail(forHistoryEntry entry: DeliveryHistoryEntry) {
        guard isPresentingDeliveryHistory,
              detailActionInProgress == nil,
              let history = deliveryHistory,
              let parentItem = selectedItem,
              let parentDetail = detail,
              let destinationURL = entry.destinationURL
        else {
            return
        }

        deliveryHistoryTask?.cancel()
        deliveryHistoryTask = nil
        detailActionTask?.cancel()
        detailActionTask = nil

        deliveryHistoryParentItem = parentItem
        deliveryHistoryParentDetail = parentDetail
        isPresentingDeliveryHistory = false
        isPresentingHistoryEntryDetail = true
        selectedItem = ActivityItem(
            id: entry.id,
            repository: history.repository,
            context: entry.title,
            detail: entry.detail ?? "Completed workflow run",
            state: activityState(for: entry.state),
            destinationURL: destinationURL,
            kind: .workflowRun,
            updatedAt: entry.occurredAt
        )
        detail = nil
        detailErrorMessage = nil
        detailActionErrorMessage = nil
        detailActionInProgress = nil
        detailIsLoading = true
        loadSelectedDetail()
    }

    func returnToDeliveryHistory() {
        guard isPresentingHistoryEntryDetail,
              let parentItem = deliveryHistoryParentItem,
              let parentDetail = deliveryHistoryParentDetail,
              deliveryHistory != nil
        else {
            return
        }

        detailTask?.cancel()
        detailTask = nil
        detailActionTask?.cancel()
        detailActionTask = nil
        selectedItem = parentItem
        detail = parentDetail
        detailErrorMessage = nil
        detailIsLoading = false
        detailActionInProgress = nil
        detailActionErrorMessage = nil
        isPresentingHistoryEntryDetail = false
        isPresentingDeliveryHistory = true
        deliveryHistoryParentItem = nil
        deliveryHistoryParentDetail = nil
    }

    func dismissDeliveryHistory() {
        deliveryHistoryTask?.cancel()
        deliveryHistoryTask = nil
        clearHistoryEntryDetailNavigation()
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
        detailActionInProgress = nil
        detailActionErrorMessage = nil
        clearHistoryEntryDetailNavigation()
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
                guard ActivityCollectionLimitPolicy.allows(loaded) else {
                    deliveryHistory = nil
                    deliveryHistoryErrorMessage =
                        "Could not load delivery history."
                    deliveryHistoryIsLoading = false
                    return
                }
                guard ActivityDestinationURLPolicy.allows(loaded) else {
                    deliveryHistory = nil
                    deliveryHistoryErrorMessage =
                        "Could not load delivery history."
                    deliveryHistoryIsLoading = false
                    return
                }
                guard ActivityPresentationTextPolicy.allows(loaded) else {
                    deliveryHistory = nil
                    deliveryHistoryErrorMessage =
                        "Could not load delivery history."
                    deliveryHistoryIsLoading = false
                    return
                }
                guard ActivityDetailStructurePolicy.allows(
                    loaded,
                    selectedItem: item
                ) else {
                    deliveryHistory = nil
                    deliveryHistoryErrorMessage =
                        "Could not load delivery history."
                    deliveryHistoryIsLoading = false
                    return
                }
                guard ActivityDeliveryTimestampPolicy.allows(loaded) else {
                    deliveryHistory = nil
                    deliveryHistoryErrorMessage =
                        "Could not load delivery history."
                    deliveryHistoryIsLoading = false
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

    private func clearHistoryEntryDetailNavigation() {
        isPresentingHistoryEntryDetail = false
        deliveryHistoryParentItem = nil
        deliveryHistoryParentDetail = nil
    }

    private func activityState(
        for detailState: ActivityDetailState
    ) -> ActivityState {
        switch detailState {
        case .failed:
            return .failed
        case .running:
            return .running
        case .waiting:
            return .waiting
        case .success, .neutral:
            return .success
        }
    }

    private func detailActionFailureMessage(
        for action: ActivityDetailAction
    ) -> String {
        switch action {
        case .rerunWorkflow:
            return "Could not re-run this workflow."
        case .cancelWorkflow:
            return "Could not cancel this workflow."
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
                guard ActivityCollectionLimitPolicy.allows(loaded) else {
                    detail = nil
                    detailErrorMessage =
                        "Could not load workflow job details."
                    detailIsLoading = false
                    return
                }
                guard ActivityDestinationURLPolicy.allows(loaded) else {
                    detail = nil
                    detailErrorMessage =
                        "Could not load workflow job details."
                    detailIsLoading = false
                    return
                }
                guard ActivityPresentationTextPolicy.allows(loaded) else {
                    detail = nil
                    detailErrorMessage =
                        "Could not load workflow job details."
                    detailIsLoading = false
                    return
                }
                guard ActivityDetailStructurePolicy.allows(
                    loaded,
                    selectedItem: item
                ) else {
                    detail = nil
                    detailErrorMessage =
                        "Could not load workflow job details."
                    detailIsLoading = false
                    return
                }
                guard ActivityDeliveryTimestampPolicy.allows(loaded) else {
                    detail = nil
                    detailErrorMessage =
                        "Could not load workflow job details."
                    detailIsLoading = false
                    return
                }
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

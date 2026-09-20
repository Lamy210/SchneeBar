@testable import SchneeBar
import Foundation
import SchneeBarCore
import Testing

private actor HistoryLoadCounter {
    private var count = 0

    func next() -> Int {
        count += 1
        return count
    }

    func value() -> Int { count }
}

@Test @MainActor
func activityRuntimeHistoryPreservesLoadedDetailAndBackDoesNotReloadDetail() async throws {
    let model = ActivityRuntimeModel()
    let item = historyRuntimeItem()
    let detail = historyRuntimeDetail(item: item)
    let history = historyRuntimeSnapshot()
    let detailCounter = HistoryLoadCounter()
    let historyCounter = HistoryLoadCounter()

    model.configureDetailLoader { _ in
        _ = await detailCounter.next()
        return detail
    }
    model.configureDeliveryHistoryLoader { _ in
        _ = await historyCounter.next()
        return history
    }

    model.selectedItem = item
    model.detail = detail
    model.requestDeliveryHistory()
    await waitForHistoryLoad(model)

    #expect(model.isPresentingDeliveryHistory)
    #expect(model.selectedItem == item)
    #expect(model.detail == detail)
    #expect(model.deliveryHistory == history)
    #expect(await detailCounter.value() == 0)
    #expect(await historyCounter.value() == 1)

    model.dismissDeliveryHistory()

    #expect(!model.isPresentingDeliveryHistory)
    #expect(model.selectedItem == item)
    #expect(model.detail == detail)
    #expect(model.deliveryHistory == nil)
    #expect(await detailCounter.value() == 0)
}

@Test @MainActor
func activityRuntimeHistoryRetryOnlyRepeatsHistoryLoader() async throws {
    let model = ActivityRuntimeModel()
    let item = historyRuntimeItem()
    let detail = historyRuntimeDetail(item: item)
    let detailCounter = HistoryLoadCounter()
    let historyCounter = HistoryLoadCounter()

    model.selectedItem = item
    model.detail = detail
    model.configureDetailLoader { _ in
        _ = await detailCounter.next()
        return detail
    }
    model.configureDeliveryHistoryLoader { _ in
        let attempt = await historyCounter.next()
        if attempt == 1 {
            throw HistoryRuntimeError.failed
        }
        return historyRuntimeSnapshot()
    }

    model.requestDeliveryHistory()
    await waitForHistoryLoad(model)
    #expect(model.deliveryHistory == nil)
    #expect(model.deliveryHistoryErrorMessage != nil)

    model.retryDeliveryHistory()
    await waitForHistoryLoad(model)

    #expect(model.deliveryHistory == historyRuntimeSnapshot())
    #expect(model.deliveryHistoryErrorMessage == nil)
    #expect(await historyCounter.value() == 2)
    #expect(await detailCounter.value() == 0)
}

@Test @MainActor
func activityRuntimeHistoryDismissCancelsStaleCompletion() async throws {
    let model = ActivityRuntimeModel()
    let item = historyRuntimeItem()
    let detail = historyRuntimeDetail(item: item)

    model.selectedItem = item
    model.detail = detail
    model.configureDeliveryHistoryLoader { _ in
        try await Task.sleep(nanoseconds: 5_000_000_000)
        return historyRuntimeSnapshot()
    }

    model.requestDeliveryHistory()
    #expect(model.deliveryHistoryIsLoading)
    model.dismissDeliveryHistory()

    await Task.yield()
    await Task.yield()

    #expect(!model.isPresentingDeliveryHistory)
    #expect(!model.deliveryHistoryIsLoading)
    #expect(model.deliveryHistory == nil)
    #expect(model.selectedItem == item)
    #expect(model.detail == detail)
}

@Test @MainActor
func activityRuntimeDismissDetailClearsHistoryState() async throws {
    let model = ActivityRuntimeModel()
    let item = historyRuntimeItem()
    model.selectedItem = item
    model.detail = historyRuntimeDetail(item: item)
    model.configureDeliveryHistoryLoader { _ in historyRuntimeSnapshot() }

    model.requestDeliveryHistory()
    await waitForHistoryLoad(model)
    model.dismissDetail()

    #expect(model.selectedItem == nil)
    #expect(model.detail == nil)
    #expect(!model.isPresentingDeliveryHistory)
    #expect(model.deliveryHistory == nil)
    #expect(model.deliveryHistoryErrorMessage == nil)
    #expect(!model.deliveryHistoryIsLoading)
}

private enum HistoryRuntimeError: Error {
    case failed
}

@MainActor
private func waitForHistoryLoad(_ model: ActivityRuntimeModel) async {
    for _ in 0 ..< 1_000 {
        if !model.deliveryHistoryIsLoading {
            return
        }
        await Task.yield()
    }
}

private func historyRuntimeItem() -> ActivityItem {
    ActivityItem(
        id: "github-actions:1:700",
        repository: "snow/app",
        context: "CI",
        detail: "Succeeded",
        state: .success,
        destinationURL: URL(string: "https://github.com/snow/app/actions/runs/700"),
        kind: .workflowRun,
        updatedAt: Date(timeIntervalSince1970: 100)
    )
}

private func historyRuntimeDetail(
    item: ActivityItem
) -> ActivityDetailSnapshot {
    ActivityDetailSnapshot(
        id: item.id,
        repository: item.repository,
        title: item.context,
        summary: "1 job",
        state: item.state,
        destinationURL: item.destinationURL,
        rows: []
    )
}

private func historyRuntimeSnapshot() -> DeliveryHistorySnapshot {
    DeliveryHistorySnapshot(
        repository: "snow/app",
        entries: [
            DeliveryHistoryEntry(
                id: "github-actions:1:700",
                title: "CI",
                detail: "Succeeded · Default branch · Run #700",
                state: .success,
                destinationURL: URL(string: "https://github.com/snow/app/actions/runs/700"),
                occurredAt: Date(timeIntervalSince1970: 100)
            ),
        ]
    )
}

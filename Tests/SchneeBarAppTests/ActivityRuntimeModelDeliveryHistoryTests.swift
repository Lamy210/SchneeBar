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

private actor HistoryItemRecorder {
    private var items: [ActivityItem] = []

    func record(_ item: ActivityItem) {
        items.append(item)
    }

    func values() -> [ActivityItem] {
        items
    }
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
func activityRuntimeHistoryEntryDrilldownLoadsDetailAndReturnsWithoutReloadingHistory() async throws {
    let model = ActivityRuntimeModel()
    let parentItem = historyRuntimeItem()
    let parentDetail = historyRuntimeDetail(item: parentItem)
    let history = historyRuntimeSnapshot(runID: 699)
    let detailCounter = HistoryLoadCounter()
    let historyCounter = HistoryLoadCounter()
    let recorder = HistoryItemRecorder()

    model.selectedItem = parentItem
    model.detail = parentDetail
    model.configureDeliveryHistoryLoader { _ in
        _ = await historyCounter.next()
        return history
    }
    model.configureDetailLoader { item in
        _ = await detailCounter.next()
        await recorder.record(item)
        return historyRuntimeDetail(item: item)
    }

    model.requestDeliveryHistory()
    await waitForHistoryLoad(model)
    let entry = try #require(model.deliveryHistory?.entries.first)

    model.requestDetail(forHistoryEntry: entry)
    await waitForDetailLoad(model)

    #expect(!model.isPresentingDeliveryHistory)
    #expect(model.isPresentingHistoryEntryDetail)
    #expect(model.selectedItem?.id == entry.id)
    #expect(model.selectedItem?.repository == history.repository)
    #expect(model.selectedItem?.context == entry.title)
    #expect(model.selectedItem?.destinationURL == entry.destinationURL)
    #expect(model.detail?.id == entry.id)
    #expect(model.deliveryHistory == history)
    #expect(await historyCounter.value() == 1)
    #expect(await detailCounter.value() == 1)

    let recorded = await recorder.values()
    #expect(recorded.count == 1)
    #expect(recorded.first?.updatedAt == entry.occurredAt)

    model.returnToDeliveryHistory()

    #expect(model.isPresentingDeliveryHistory)
    #expect(!model.isPresentingHistoryEntryDetail)
    #expect(model.selectedItem == parentItem)
    #expect(model.detail == parentDetail)
    #expect(model.deliveryHistory == history)
    #expect(await historyCounter.value() == 1)
    #expect(await detailCounter.value() == 1)
}

@Test @MainActor
func activityRuntimeHistoryEntryDrilldownSurvivesInboxRefresh() async throws {
    let model = ActivityRuntimeModel()
    let parentItem = historyRuntimeItem()
    let refreshedParent = ActivityItem(
        id: parentItem.id,
        repository: parentItem.repository,
        context: "CI refreshed",
        detail: parentItem.detail,
        state: parentItem.state,
        destinationURL: parentItem.destinationURL,
        kind: parentItem.kind,
        updatedAt: Date(timeIntervalSince1970: 200)
    )
    let history = historyRuntimeSnapshot(runID: 699)

    model.selectedItem = parentItem
    model.detail = historyRuntimeDetail(item: parentItem)
    model.configureDeliveryHistoryLoader { _ in history }
    model.configureDetailLoader { item in
        historyRuntimeDetail(item: item)
    }

    model.requestDeliveryHistory()
    await waitForHistoryLoad(model)
    let entry = try #require(model.deliveryHistory?.entries.first)
    model.requestDetail(forHistoryEntry: entry)
    await waitForDetailLoad(model)

    model.replace(with: [refreshedParent])

    #expect(model.isPresentingHistoryEntryDetail)
    #expect(model.selectedItem?.id == entry.id)
    #expect(model.detail?.id == entry.id)

    model.returnToDeliveryHistory()

    #expect(model.selectedItem == refreshedParent)
    #expect(model.isPresentingDeliveryHistory)
}

@Test @MainActor
func activityRuntimeHistoryEntryWithoutDestinationDoesNotNavigate() async throws {
    let model = ActivityRuntimeModel()
    let parentItem = historyRuntimeItem()
    let parentDetail = historyRuntimeDetail(item: parentItem)
    let entry = DeliveryHistoryEntry(
        id: "github-actions:1:699",
        title: "CI",
        detail: "Succeeded · main · Run #699",
        state: .success,
        destinationURL: nil,
        occurredAt: Date(timeIntervalSince1970: 99)
    )
    let history = DeliveryHistorySnapshot(
        repository: parentItem.repository,
        entries: [entry]
    )

    model.selectedItem = parentItem
    model.detail = parentDetail
    model.configureDeliveryHistoryLoader { _ in history }
    model.requestDeliveryHistory()
    await waitForHistoryLoad(model)

    model.requestDetail(forHistoryEntry: entry)

    #expect(model.isPresentingDeliveryHistory)
    #expect(!model.isPresentingHistoryEntryDetail)
    #expect(model.selectedItem == parentItem)
    #expect(model.detail == parentDetail)
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

@MainActor
private func waitForDetailLoad(_ model: ActivityRuntimeModel) async {
    for _ in 0 ..< 1_000 {
        if !model.detailIsLoading {
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

private func historyRuntimeSnapshot(
    runID: Int64 = 700
) -> DeliveryHistorySnapshot {
    DeliveryHistorySnapshot(
        repository: "snow/app",
        entries: [
            DeliveryHistoryEntry(
                id: "github-actions:1:\(runID)",
                title: "CI",
                detail: "Succeeded · Default branch · Run #\(runID)",
                state: .success,
                destinationURL: URL(
                    string: "https://github.com/snow/app/actions/runs/\(runID)"
                ),
                occurredAt: Date(timeIntervalSince1970: TimeInterval(runID))
            ),
        ]
    )
}

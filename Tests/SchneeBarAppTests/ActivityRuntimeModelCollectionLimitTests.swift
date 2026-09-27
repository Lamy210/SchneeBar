@testable import SchneeBar
import Foundation
import SchneeBarCore
import Testing

@Test @MainActor
func activityRuntimeRejectsOversizedDetailCollectionBeforeUIState() async {
    let model = ActivityRuntimeModel()
    let item = collectionRuntimeItem()

    model.configureDetailLoader { item in
        ActivityDetailSnapshot(
            id: item.id,
            repository: item.repository,
            title: item.context,
            summary: "Too many jobs",
            state: item.state,
            rows: (0 ..< 1_025).map { index in
                ActivityDetailRow(
                    id: "job-\(index)",
                    title: "Job",
                    state: .success
                )
            }
        )
    }

    model.requestDetail(for: item)
    await waitForCollectionDetailLoad(model)

    #expect(model.detail == nil)
    #expect(
        model.detailErrorMessage
            == "Could not load workflow job details."
    )
    #expect(!model.detailIsLoading)
}

@Test @MainActor
func activityRuntimeRejectsOversizedHistoryCollectionBeforeUIState() async {
    let model = ActivityRuntimeModel()
    let item = collectionRuntimeItem()

    model.selectedItem = item
    model.detail = ActivityDetailSnapshot(
        id: item.id,
        repository: item.repository,
        title: item.context,
        summary: "1 job",
        state: item.state,
        rows: []
    )
    model.configureDeliveryHistoryLoader { _ in
        DeliveryHistorySnapshot(
            repository: item.repository,
            entries: (0 ..< 201).map { index in
                DeliveryHistoryEntry(
                    id: "run-\(index)",
                    title: "Run",
                    state: .success,
                    occurredAt: Date(
                        timeIntervalSince1970: Double(index)
                    )
                )
            }
        )
    }

    model.requestDeliveryHistory()
    await waitForCollectionHistoryLoad(model)

    #expect(model.deliveryHistory == nil)
    #expect(
        model.deliveryHistoryErrorMessage
            == "Could not load delivery history."
    )
    #expect(!model.deliveryHistoryIsLoading)
}

private func collectionRuntimeItem() -> ActivityItem {
    ActivityItem(
        id: "github-actions:1:700",
        repository: "snow/app",
        context: "CI",
        detail: "Succeeded",
        state: .success,
        updatedAt: Date(timeIntervalSince1970: 100)
    )
}

@MainActor
private func waitForCollectionDetailLoad(
    _ model: ActivityRuntimeModel
) async {
    for _ in 0 ..< 1_000 {
        if !model.detailIsLoading {
            return
        }
        await Task.yield()
    }
}

@MainActor
private func waitForCollectionHistoryLoad(
    _ model: ActivityRuntimeModel
) async {
    for _ in 0 ..< 1_000 {
        if !model.deliveryHistoryIsLoading {
            return
        }
        await Task.yield()
    }
}

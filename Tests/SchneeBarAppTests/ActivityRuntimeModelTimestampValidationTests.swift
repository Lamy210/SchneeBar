@testable import SchneeBar
import Foundation
import SchneeBarCore
import Testing

@Test @MainActor
func activityRuntimeRejectsNonFiniteTimelineTimestampBeforeUIState() async {
    let model = ActivityRuntimeModel()
    let item = timestampRuntimeItem()

    model.configureDetailLoader { item in
        ActivityDetailSnapshot(
            id: item.id,
            repository: item.repository,
            title: item.context,
            summary: "Delivery",
            state: item.state,
            deliveryTimeline: DeliveryTimelineSnapshot(
                status: .correlated,
                confidence: .exact,
                events: [
                    DeliveryTimelineEvent(
                        id: "run",
                        kind: .execution,
                        title: "Run",
                        state: .success,
                        occurredAt: Date(
                            timeIntervalSinceReferenceDate: .nan
                        )
                    ),
                ]
            ),
            rows: []
        )
    }

    model.requestDetail(for: item)
    await waitForTimestampDetailLoad(model)

    #expect(model.detail == nil)
    #expect(
        model.detailErrorMessage
            == "Could not load workflow job details."
    )
    #expect(!model.detailIsLoading)
}

@Test @MainActor
func activityRuntimeRejectsNonFiniteHistoryTimestampBeforeUIState() async {
    let model = ActivityRuntimeModel()
    let item = timestampRuntimeItem()

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
            entries: [
                DeliveryHistoryEntry(
                    id: "run",
                    title: "Run",
                    state: .success,
                    occurredAt: Date(
                        timeIntervalSinceReferenceDate: .infinity
                    )
                ),
            ]
        )
    }

    model.requestDeliveryHistory()
    await waitForTimestampHistoryLoad(model)

    #expect(model.deliveryHistory == nil)
    #expect(
        model.deliveryHistoryErrorMessage
            == "Could not load delivery history."
    )
    #expect(!model.deliveryHistoryIsLoading)
}

private func timestampRuntimeItem() -> ActivityItem {
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
private func waitForTimestampDetailLoad(
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
private func waitForTimestampHistoryLoad(
    _ model: ActivityRuntimeModel
) async {
    for _ in 0 ..< 1_000 {
        if !model.deliveryHistoryIsLoading {
            return
        }
        await Task.yield()
    }
}

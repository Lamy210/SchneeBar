@testable import SchneeBar
import Foundation
import SchneeBarCore
import Testing

@Test @MainActor
func activityRuntimeRejectsMismatchedDetailIdentityBeforeUIState() async {
    let model = ActivityRuntimeModel()
    let item = structureRuntimeItem()

    model.configureDetailLoader { item in
        ActivityDetailSnapshot(
            id: "github-actions:1:999",
            repository: item.repository,
            title: item.context,
            summary: "1 job",
            state: item.state,
            rows: []
        )
    }

    model.requestDetail(for: item)
    await waitForStructureDetailLoad(model)

    #expect(model.detail == nil)
    #expect(
        model.detailErrorMessage
            == "Could not load workflow job details."
    )
    #expect(!model.detailIsLoading)
}

@Test @MainActor
func activityRuntimeRejectsDuplicateDetailIdentityBeforeUIState() async {
    let model = ActivityRuntimeModel()
    let item = structureRuntimeItem()

    model.configureDetailLoader { item in
        ActivityDetailSnapshot(
            id: item.id,
            repository: item.repository,
            title: item.context,
            summary: "2 jobs",
            state: item.state,
            rows: [
                ActivityDetailRow(
                    id: "job",
                    title: "Job A",
                    state: .success
                ),
                ActivityDetailRow(
                    id: "job",
                    title: "Job B",
                    state: .success
                ),
            ]
        )
    }

    model.requestDetail(for: item)
    await waitForStructureDetailLoad(model)

    #expect(model.detail == nil)
    #expect(
        model.detailErrorMessage
            == "Could not load workflow job details."
    )
}

@Test @MainActor
func activityRuntimeRejectsMismatchedHistoryRepositoryBeforeUIState() async {
    let model = ActivityRuntimeModel()
    let item = structureRuntimeItem()

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
            repository: "other/repo",
            entries: []
        )
    }

    model.requestDeliveryHistory()
    await waitForStructureHistoryLoad(model)

    #expect(model.deliveryHistory == nil)
    #expect(
        model.deliveryHistoryErrorMessage
            == "Could not load delivery history."
    )
    #expect(!model.deliveryHistoryIsLoading)
}

private func structureRuntimeItem() -> ActivityItem {
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
private func waitForStructureDetailLoad(
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
private func waitForStructureHistoryLoad(
    _ model: ActivityRuntimeModel
) async {
    for _ in 0 ..< 1_000 {
        if !model.deliveryHistoryIsLoading {
            return
        }
        await Task.yield()
    }
}

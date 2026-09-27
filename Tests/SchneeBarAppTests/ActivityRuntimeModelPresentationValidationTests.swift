@testable import SchneeBar
import Foundation
import SchneeBarCore
import Testing

@Test @MainActor
func activityRuntimeRejectsUnsafeDetailPresentationBeforeUIState() async throws {
    let model = ActivityRuntimeModel()
    let item = try presentationRuntimeItem()

    model.configureDetailLoader { item in
        ActivityDetailSnapshot(
            id: item.id,
            repository: item.repository,
            title: item.context,
            summary: "1 job",
            state: item.state,
            rows: [
                ActivityDetailRow(
                    id: "job",
                    title: "unsafe\njob",
                    state: .failed
                ),
            ]
        )
    }

    model.requestDetail(for: item)
    await waitForPresentationDetailLoad(model)

    #expect(model.detail == nil)
    #expect(
        model.detailErrorMessage
            == "Could not load workflow job details."
    )
    #expect(!model.detailIsLoading)
}

@Test @MainActor
func activityRuntimeAcceptsSafeDetailPresentation() async throws {
    let model = ActivityRuntimeModel()
    let item = try presentationRuntimeItem()

    model.configureDetailLoader { item in
        ActivityDetailSnapshot(
            id: item.id,
            repository: item.repository,
            title: item.context,
            summary: "1 job",
            state: item.state,
            rows: [
                ActivityDetailRow(
                    id: "job",
                    title: "macOS",
                    detail: "Succeeded",
                    state: .success
                ),
            ]
        )
    }

    model.requestDetail(for: item)
    await waitForPresentationDetailLoad(model)

    #expect(model.detail?.rows.first?.title == "macOS")
    #expect(model.detailErrorMessage == nil)
    #expect(!model.detailIsLoading)
}

@Test @MainActor
func activityRuntimeRejectsUnsafeHistoryPresentationBeforeUIState() async throws {
    let model = ActivityRuntimeModel()
    let item = try presentationRuntimeItem()

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
                    title: " ",
                    state: .success,
                    occurredAt: Date(timeIntervalSince1970: 100)
                ),
            ]
        )
    }

    model.requestDeliveryHistory()
    await waitForPresentationHistoryLoad(model)

    #expect(model.deliveryHistory == nil)
    #expect(
        model.deliveryHistoryErrorMessage
            == "Could not load delivery history."
    )
    #expect(!model.deliveryHistoryIsLoading)
}

private func presentationRuntimeItem() throws -> ActivityItem {
    ActivityItem(
        id: "github-actions:1:700",
        repository: "snow/app",
        context: "CI",
        detail: "Succeeded",
        state: .success,
        destinationURL: try #require(
            URL(
                string:
                    "https://github.com/snow/app/actions/runs/700"
            )
        ),
        kind: .workflowRun,
        updatedAt: Date(timeIntervalSince1970: 100)
    )
}

@MainActor
private func waitForPresentationDetailLoad(
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
private func waitForPresentationHistoryLoad(
    _ model: ActivityRuntimeModel
) async {
    for _ in 0 ..< 1_000 {
        if !model.deliveryHistoryIsLoading {
            return
        }
        await Task.yield()
    }
}

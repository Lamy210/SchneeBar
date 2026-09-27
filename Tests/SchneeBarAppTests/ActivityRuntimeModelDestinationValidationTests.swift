@testable import SchneeBar
import Foundation
import SchneeBarCore
import Testing

@Test @MainActor
func activityRuntimeRejectsUnsafeDetailBeforeUIState() async throws {
    let model = ActivityRuntimeModel()
    let item = try destinationRuntimeItem()
    let unsafeURL = try #require(
        URL(string: "file:///tmp/job")
    )

    model.configureDetailLoader { item in
        ActivityDetailSnapshot(
            id: item.id,
            repository: item.repository,
            title: item.context,
            summary: "1 job",
            state: item.state,
            destinationURL: item.destinationURL,
            rows: [
                ActivityDetailRow(
                    id: "job",
                    title: "Job",
                    state: .success,
                    destinationURL: unsafeURL
                ),
            ]
        )
    }

    model.requestDetail(for: item)
    await waitForDestinationDetailLoad(model)

    #expect(model.detail == nil)
    #expect(
        model.detailErrorMessage
            == "Could not load workflow job details."
    )
    #expect(!model.detailIsLoading)
}

@Test @MainActor
func activityRuntimeAcceptsSafeDetailDestinations() async throws {
    let model = ActivityRuntimeModel()
    let item = try destinationRuntimeItem()
    let safeURL = try #require(
        URL(
            string:
                "https://github.internal.example:8443/snow/app/actions/runs/700/job/1"
        )
    )

    model.configureDetailLoader { item in
        ActivityDetailSnapshot(
            id: item.id,
            repository: item.repository,
            title: item.context,
            summary: "1 job",
            state: item.state,
            destinationURL: item.destinationURL,
            rows: [
                ActivityDetailRow(
                    id: "job",
                    title: "Job",
                    state: .success,
                    destinationURL: safeURL
                ),
            ]
        )
    }

    model.requestDetail(for: item)
    await waitForDestinationDetailLoad(model)

    #expect(model.detail?.rows.first?.destinationURL == safeURL)
    #expect(model.detailErrorMessage == nil)
}

@Test @MainActor
func activityRuntimeRejectsUnsafeHistoryBeforeUIState() async throws {
    let model = ActivityRuntimeModel()
    let item = try destinationRuntimeItem()
    let detail = destinationRuntimeDetail(item: item)
    let unsafeURL = try #require(
        URL(string: "custom://example.com/run")
    )

    model.selectedItem = item
    model.detail = detail
    model.configureDeliveryHistoryLoader { _ in
        DeliveryHistorySnapshot(
            repository: item.repository,
            entries: [
                DeliveryHistoryEntry(
                    id: "run",
                    title: "Run",
                    state: .success,
                    destinationURL: unsafeURL,
                    occurredAt: Date(timeIntervalSince1970: 100)
                ),
            ]
        )
    }

    model.requestDeliveryHistory()
    await waitForDestinationHistoryLoad(model)

    #expect(model.deliveryHistory == nil)
    #expect(
        model.deliveryHistoryErrorMessage
            == "Could not load delivery history."
    )
    #expect(!model.deliveryHistoryIsLoading)
}

private func destinationRuntimeItem() throws -> ActivityItem {
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

private func destinationRuntimeDetail(
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

@MainActor
private func waitForDestinationDetailLoad(
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
private func waitForDestinationHistoryLoad(
    _ model: ActivityRuntimeModel
) async {
    for _ in 0 ..< 1_000 {
        if !model.deliveryHistoryIsLoading {
            return
        }
        await Task.yield()
    }
}

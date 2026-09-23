@testable import SchneeBar
import Foundation
import SchneeBarCore
import Testing

private actor WorkflowActionCounter {
    private var count = 0

    func increment() {
        count += 1
    }

    func value() -> Int {
        count
    }
}

private enum WorkflowActionTestError: Error {
    case failed
}

@Test @MainActor
func workflowActionSuccessReloadsSelectedDetail() async throws {
    let model = ActivityRuntimeModel()
    let item = workflowActionItem(state: .failed)
    let initial = workflowActionDetail(
        item: item,
        actions: [.rerunWorkflow]
    )
    let refreshed = workflowActionDetail(
        item: item,
        state: .running,
        actions: [.cancelWorkflow]
    )
    let actionCounter = WorkflowActionCounter()
    let detailCounter = WorkflowActionCounter()

    model.selectedItem = item
    model.detail = initial
    model.configureDetailActionHandler { _, action in
        #expect(action == .rerunWorkflow)
        await actionCounter.increment()
    }
    model.configureDetailLoader { _ in
        await detailCounter.increment()
        return refreshed
    }

    model.performDetailAction(.rerunWorkflow)
    await waitForWorkflowActionToSettle(model)

    #expect(await actionCounter.value() == 1)
    #expect(await detailCounter.value() == 1)
    #expect(model.detail == refreshed)
    #expect(model.detailActionInProgress == nil)
    #expect(model.detailActionErrorMessage == nil)
}

@Test @MainActor
func workflowActionFailureKeepsExistingDetailAndSurfacesError() async throws {
    let model = ActivityRuntimeModel()
    let item = workflowActionItem(state: .running)
    let detail = workflowActionDetail(
        item: item,
        actions: [.cancelWorkflow]
    )
    let detailCounter = WorkflowActionCounter()

    model.selectedItem = item
    model.detail = detail
    model.configureDetailActionHandler { _, _ in
        throw WorkflowActionTestError.failed
    }
    model.configureDetailLoader { _ in
        await detailCounter.increment()
        return detail
    }

    model.performDetailAction(.cancelWorkflow)
    await waitForWorkflowActionToSettle(model)

    #expect(model.detail == detail)
    #expect(model.detailActionInProgress == nil)
    #expect(
        model.detailActionErrorMessage
            == "Could not cancel this workflow."
    )
    #expect(await detailCounter.value() == 0)
}

@Test @MainActor
func workflowActionCannotBypassDetailAvailabilityGate() async throws {
    let model = ActivityRuntimeModel()
    let item = workflowActionItem(state: .failed)
    let counter = WorkflowActionCounter()

    model.selectedItem = item
    model.detail = workflowActionDetail(item: item, actions: [])
    model.configureDetailActionHandler { _, _ in
        await counter.increment()
    }

    model.performDetailAction(.rerunWorkflow)
    await Task.yield()

    #expect(await counter.value() == 0)
    #expect(model.detailActionInProgress == nil)
}

@Test @MainActor
func replacingDetailCancelsStaleWorkflowAction() async throws {
    let model = ActivityRuntimeModel()
    let first = workflowActionItem(id: "first", state: .failed)
    let second = workflowActionItem(id: "second", state: .failed)

    model.selectedItem = first
    model.detail = workflowActionDetail(
        item: first,
        actions: [.rerunWorkflow]
    )
    model.configureDetailActionHandler { _, _ in
        try await Task.sleep(nanoseconds: 5_000_000_000)
    }
    model.configureDetailLoader { item in
        workflowActionDetail(item: item, actions: [])
    }

    model.performDetailAction(.rerunWorkflow)
    #expect(model.detailActionInProgress == .rerunWorkflow)

    model.requestDetail(for: second)
    await waitForDetailLoad(model)

    #expect(model.selectedItem == second)
    #expect(model.detail?.id == second.id)
    #expect(model.detailActionInProgress == nil)
    #expect(model.detailActionErrorMessage == nil)
}

@MainActor
private func waitForWorkflowActionToSettle(
    _ model: ActivityRuntimeModel
) async {
    for _ in 0 ..< 2_000 {
        if model.detailActionInProgress == nil,
           !model.detailIsLoading
        {
            return
        }
        await Task.yield()
    }
}

@MainActor
private func waitForDetailLoad(
    _ model: ActivityRuntimeModel
) async {
    for _ in 0 ..< 2_000 {
        if !model.detailIsLoading {
            return
        }
        await Task.yield()
    }
}

private func workflowActionItem(
    id: String = "github-actions:1:700",
    state: ActivityState
) -> ActivityItem {
    ActivityItem(
        id: id,
        repository: "snow/app",
        context: "CI",
        detail: "Workflow",
        state: state,
        destinationURL: URL(
            string: "https://github.com/snow/app/actions/runs/700"
        ),
        kind: .workflowRun
    )
}

private func workflowActionDetail(
    item: ActivityItem,
    state: ActivityState? = nil,
    actions: [ActivityDetailAction]
) -> ActivityDetailSnapshot {
    ActivityDetailSnapshot(
        id: item.id,
        repository: item.repository,
        title: item.context,
        summary: "1 job",
        state: state ?? item.state,
        destinationURL: item.destinationURL,
        actions: actions,
        rows: []
    )
}

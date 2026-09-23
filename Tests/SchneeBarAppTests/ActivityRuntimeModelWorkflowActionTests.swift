@testable import SchneeBar
import Foundation
import SchneeBarCore
import Testing

private actor WorkflowActionRecorder {
    private var actions: [ActivityDetailAction] = []

    func record(_ action: ActivityDetailAction) {
        actions.append(action)
    }

    func recorded() -> [ActivityDetailAction] {
        actions
    }
}

private actor WorkflowActionLoadCounter {
    private var valueStorage = 0

    func increment() -> Int {
        valueStorage += 1
        return valueStorage
    }

    func value() -> Int {
        valueStorage
    }
}

private enum WorkflowActionTestError: Error {
    case failed
}

@Test @MainActor
func successfulWorkflowActionReloadsCurrentDetail() async throws {
    let model = ActivityRuntimeModel()
    let item = workflowActionItem(state: .failed)
    let detail = workflowActionDetail(
        item: item,
        actions: [.rerunWorkflow]
    )
    let recorder = WorkflowActionRecorder()
    let loads = WorkflowActionLoadCounter()

    model.selectedItem = item
    model.detail = detail
    model.configureDetailLoader { _ in
        _ = await loads.increment()
        return detail
    }
    model.configureDetailActionPerformer { _, action in
        await recorder.record(action)
    }

    model.performDetailAction(.rerunWorkflow)
    await waitForWorkflowAction(model)

    #expect(await recorder.recorded() == [.rerunWorkflow])
    #expect(await loads.value() == 1)
    #expect(model.detailActionErrorMessage == nil)
    #expect(!model.detailActionIsRunning)
}

@Test @MainActor
func failedWorkflowActionPreservesLoadedDetailAndShowsError() async throws {
    let model = ActivityRuntimeModel()
    let item = workflowActionItem(state: .running)
    let detail = workflowActionDetail(
        item: item,
        actions: [.cancelWorkflow]
    )
    let loads = WorkflowActionLoadCounter()

    model.selectedItem = item
    model.detail = detail
    model.configureDetailLoader { _ in
        _ = await loads.increment()
        return detail
    }
    model.configureDetailActionPerformer { _, _ in
        throw WorkflowActionTestError.failed
    }

    model.performDetailAction(.cancelWorkflow)
    await waitForWorkflowAction(model)

    #expect(model.detail == detail)
    #expect(model.detailActionErrorMessage == "Could not cancel workflow.")
    #expect(await loads.value() == 0)
    #expect(!model.detailActionIsRunning)
}

@Test @MainActor
func unavailableWorkflowActionDoesNotInvokePerformer() async throws {
    let model = ActivityRuntimeModel()
    let item = workflowActionItem(state: .failed)
    let detail = workflowActionDetail(item: item, actions: [])
    let recorder = WorkflowActionRecorder()

    model.selectedItem = item
    model.detail = detail
    model.configureDetailActionPerformer { _, action in
        await recorder.record(action)
    }

    model.performDetailAction(.rerunWorkflow)
    await Task.yield()

    #expect(await recorder.recorded().isEmpty)
    #expect(!model.detailActionIsRunning)
}

@MainActor
private func waitForWorkflowAction(
    _ model: ActivityRuntimeModel
) async {
    for _ in 0 ..< 2_000 {
        if !model.detailActionIsRunning && !model.detailIsLoading {
            return
        }
        await Task.yield()
    }
}

private func workflowActionItem(
    state: ActivityState
) -> ActivityItem {
    ActivityItem(
        id: "github-actions:1:700",
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
    actions: [ActivityDetailAction]
) -> ActivityDetailSnapshot {
    ActivityDetailSnapshot(
        id: item.id,
        repository: item.repository,
        title: item.context,
        summary: "1 job",
        state: item.state,
        destinationURL: item.destinationURL,
        actions: actions,
        rows: []
    )
}

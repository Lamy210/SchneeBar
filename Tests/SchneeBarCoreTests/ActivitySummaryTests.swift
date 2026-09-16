import SchneeBarCore
import Testing

@Test
func actionRequiredHasHighestSummaryPriority() {
    let summary = ActivitySummary(
        items: [
            .init(id: "review", repository: "A", context: "PR #1", detail: "Review requested", state: .waiting, kind: .reviewRequest, attention: .actionRequired),
            .init(id: "failed", repository: "B", context: "Check", detail: "Failed", state: .failed, kind: .checkRun, attention: .needsAttention),
            .init(id: "running", repository: "C", context: "CI", detail: "Running", state: .running),
        ]
    )

    #expect(summary.actionRequired == 1)
    #expect(summary.needsAttention == 1)
    #expect(summary.failed == 1)
    #expect(summary.running == 1)
    #expect(summary.waiting == 1)
    #expect(summary.menuBarLabel == "Action 1")
}

@Test
func needsAttentionIsShownWhenNoActionIsRequired() {
    let summary = ActivitySummary(
        items: [
            .init(id: "failed-1", repository: "A", context: "Check", detail: "Failed", state: .failed),
            .init(id: "failed-2", repository: "B", context: "CI", detail: "Failed", state: .failed),
        ]
    )

    #expect(summary.needsAttention == 2)
    #expect(summary.menuBarLabel == "Alert 2")
}

@Test
func runningActivityIsShownWhenNoHigherAttentionExists() {
    let summary = ActivitySummary(
        items: [
            .init(id: "running-1", repository: "A", context: "PR #1", detail: "Running", state: .running),
            .init(id: "running-2", repository: "B", context: "PR #2", detail: "Running", state: .running),
            .init(id: "waiting", repository: "C", context: "PR #3", detail: "Waiting", state: .waiting),
        ]
    )

    #expect(summary.menuBarLabel == "Running 2")
}

@Test
func waitingActivityIsShownWhenNoHigherAttentionExists() {
    let summary = ActivitySummary(
        items: [
            .init(id: "waiting-1", repository: "A", context: "PR #1", detail: "Waiting", state: .waiting),
            .init(id: "waiting-2", repository: "B", context: "PR #2", detail: "Waiting", state: .waiting),
        ]
    )

    #expect(summary.waiting == 2)
    #expect(summary.menuBarLabel == "Waiting 2")
}

@Test
func emptyActivityCollapsesToClearState() {
    let summary = ActivitySummary(items: [])

    #expect(summary.failed == 0)
    #expect(summary.running == 0)
    #expect(summary.waiting == 0)
    #expect(summary.successful == 0)
    #expect(summary.actionRequired == 0)
    #expect(summary.needsAttention == 0)
    #expect(summary.menuBarLabel == "Clear")
}

@Test
func successfulActivityCollapsesToClearState() {
    let summary = ActivitySummary(
        items: [
            .init(id: "success-1", repository: "A", context: "main", detail: "Passed", state: .success),
            .init(id: "success-2", repository: "B", context: "main", detail: "Passed", state: .success),
        ]
    )

    #expect(summary.successful == 2)
    #expect(summary.menuBarLabel == "Clear")
}

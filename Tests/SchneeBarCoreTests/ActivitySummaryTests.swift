import SchneeBarCore
import Testing

@Test
func failedActivityHasHighestMenuBarPriority() {
    let summary = ActivitySummary(
        items: [
            .init(id: "running", repository: "A", context: "main", detail: "running", state: .running),
            .init(id: "failed", repository: "B", context: "main", detail: "failed", state: .failed),
            .init(id: "waiting", repository: "C", context: "PR #3", detail: "waiting", state: .waiting),
        ]
    )

    #expect(summary.failed == 1)
    #expect(summary.running == 1)
    #expect(summary.waiting == 1)
    #expect(summary.menuBarLabel == "CI ✕1")
}

@Test
func runningActivityIsShownWhenThereAreNoFailures() {
    let summary = ActivitySummary(
        items: [
            .init(id: "running-1", repository: "A", context: "PR #1", detail: "running", state: .running),
            .init(id: "running-2", repository: "B", context: "PR #2", detail: "running", state: .running),
            .init(id: "waiting", repository: "C", context: "PR #3", detail: "waiting", state: .waiting),
        ]
    )

    #expect(summary.menuBarLabel == "CI ●2")
}

@Test
func waitingActivityIsNotReportedAsHealthy() {
    let summary = ActivitySummary(
        items: [
            .init(id: "waiting-1", repository: "A", context: "PR #1", detail: "review", state: .waiting),
            .init(id: "waiting-2", repository: "B", context: "PR #2", detail: "approval", state: .waiting),
        ]
    )

    #expect(summary.failed == 0)
    #expect(summary.running == 0)
    #expect(summary.waiting == 2)
    #expect(summary.menuBarLabel == "CI ◷2")
}

@Test
func emptyActivityCollapsesToHealthyState() {
    let summary = ActivitySummary(items: [])

    #expect(summary.failed == 0)
    #expect(summary.running == 0)
    #expect(summary.waiting == 0)
    #expect(summary.successful == 0)
    #expect(summary.menuBarLabel == "CI ✓")
}

@Test
func successfulActivityCollapsesToHealthyState() {
    let summary = ActivitySummary(
        items: [
            .init(id: "success-1", repository: "A", context: "main", detail: "passed", state: .success),
            .init(id: "success-2", repository: "B", context: "main", detail: "passed", state: .success),
        ]
    )

    #expect(summary.failed == 0)
    #expect(summary.running == 0)
    #expect(summary.waiting == 0)
    #expect(summary.successful == 2)
    #expect(summary.menuBarLabel == "CI ✓")
}

import SchneeBarCore
import Testing

@Test
func failedActivityHasHighestMenuBarPriority() {
    let summary = ActivitySummary(
        items: [
            .init(id: "running", repository: "A", context: "main", detail: "running", state: .running),
            .init(id: "failed", repository: "B", context: "main", detail: "failed", state: .failed),
        ]
    )

    #expect(summary.failed == 1)
    #expect(summary.running == 1)
    #expect(summary.menuBarLabel == "CI ✕1")
}

@Test
func runningActivityIsShownWhenThereAreNoFailures() {
    let summary = ActivitySummary(
        items: [
            .init(id: "running-1", repository: "A", context: "PR #1", detail: "running", state: .running),
            .init(id: "running-2", repository: "B", context: "PR #2", detail: "running", state: .running),
        ]
    )

    #expect(summary.menuBarLabel == "CI ●2")
}

@Test
func successfulActivityCollapsesToHealthyState() {
    let summary = ActivitySummary(items: ActivityFixtureScenario.normal.items)

    #expect(summary.failed == 0)
    #expect(summary.running == 0)
    #expect(summary.menuBarLabel == "CI ✓")
}

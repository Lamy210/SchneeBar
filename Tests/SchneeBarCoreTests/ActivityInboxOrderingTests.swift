import Foundation
import SchneeBarCore
import Testing

@Test
func ordersByAttentionThenStateThenRecency() {
    let now = Date(timeIntervalSince1970: 2_000)
    let older = Date(timeIntervalSince1970: 1_000)
    let items = [
        ActivityItem(id: "success", repository: "snow/a", context: "CI", detail: "Succeeded", state: .success, kind: .workflowRun, attention: .informational, updatedAt: now),
        ActivityItem(id: "waiting", repository: "snow/b", context: "CI", detail: "Waiting", state: .waiting, kind: .workflowRun, attention: .active, updatedAt: now),
        ActivityItem(id: "running", repository: "snow/a", context: "CI", detail: "Running", state: .running, kind: .workflowRun, attention: .active, updatedAt: older),
        ActivityItem(id: "failed-check", repository: "snow/a", context: "Codecov", detail: "Failed", state: .failed, kind: .checkRun, attention: .needsAttention, updatedAt: now),
        ActivityItem(id: "review", repository: "snow/a", context: "PR #7", detail: "Review requested", state: .waiting, kind: .reviewRequest, attention: .actionRequired, updatedAt: older),
    ]

    let sorted = items.sorted(by: ActivityInboxOrdering().areInIncreasingOrder)

    #expect(sorted.map(\.id) == ["review", "failed-check", "running", "waiting", "success"])
}

@Test
func datedItemsPrecedeUndatedItemsWithinSamePriority() {
    let dated = ActivityItem(
        id: "dated",
        repository: "snow/a",
        context: "CI",
        detail: "Running",
        state: .running,
        updatedAt: Date(timeIntervalSince1970: 100)
    )
    let undated = ActivityItem(
        id: "undated",
        repository: "snow/a",
        context: "CI",
        detail: "Running",
        state: .running
    )

    let sorted = [undated, dated].sorted(by: ActivityInboxOrdering().areInIncreasingOrder)

    #expect(sorted.map(\.id) == ["dated", "undated"])
}

@Test
func stableFieldsBreakExactPriorityTiesDeterministically() {
    let date = Date(timeIntervalSince1970: 100)
    let items = [
        ActivityItem(id: "z", repository: "snow/b", context: "same", detail: "same", state: .waiting, kind: .workflowRun, attention: .active, updatedAt: date),
        ActivityItem(id: "b", repository: "snow/a", context: "same", detail: "same", state: .waiting, kind: .workflowRun, attention: .active, updatedAt: date),
        ActivityItem(id: "a", repository: "snow/a", context: "same", detail: "same", state: .waiting, kind: .workflowRun, attention: .active, updatedAt: date),
        ActivityItem(id: "check", repository: "snow/a", context: "same", detail: "same", state: .waiting, kind: .checkRun, attention: .active, updatedAt: date),
    ]

    let sorted = items.sorted(by: ActivityInboxOrdering().areInIncreasingOrder)

    #expect(sorted.map(\.id) == ["check", "a", "b", "z"])
}

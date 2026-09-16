import Foundation
import SchneeBarCore
import Testing

@Test
func decodesLegacyActivityItemWithWorkflowDefaults() throws {
    let json = #"{"id":"legacy-1","repository":"snow/app","context":"main · CI","detail":"Running","state":"running","destinationURL":null}"#
    let item = try JSONDecoder().decode(ActivityItem.self, from: Data(json.utf8))

    #expect(item.kind == .workflowRun)
    #expect(item.attention == .active)
    #expect(item.updatedAt == nil)
}

@Test
func initializerDerivesAttentionFromStateWhenOmitted() {
    #expect(ActivityItem(id: "failed", repository: "a/b", context: "CI", detail: "Failed", state: .failed).attention == .needsAttention)
    #expect(ActivityItem(id: "running", repository: "a/b", context: "CI", detail: "Running", state: .running).attention == .active)
    #expect(ActivityItem(id: "waiting", repository: "a/b", context: "CI", detail: "Waiting", state: .waiting).attention == .active)
    #expect(ActivityItem(id: "success", repository: "a/b", context: "CI", detail: "Done", state: .success).attention == .informational)
}

@Test
func roundTripPreservesNewActivityMetadata() throws {
    let original = ActivityItem(
        id: "review-7",
        repository: "snow/app",
        context: "PR #7",
        detail: "Review requested",
        state: .waiting,
        destinationURL: URL(string: "https://github.com/snow/app/pull/7"),
        kind: .reviewRequest,
        attention: .actionRequired,
        updatedAt: Date(timeIntervalSince1970: 1_700_000_000)
    )

    let data = try JSONEncoder().encode(original)
    let decoded = try JSONDecoder().decode(ActivityItem.self, from: data)

    #expect(decoded == original)
}

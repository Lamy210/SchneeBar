@testable import SchneeBar
import SchneeBarCore
import Testing

@Test @MainActor
func activityRuntimeTracksAggregateTruncationAcrossReplacement() {
    let model = ActivityRuntimeModel()
    let item = ActivityItem(
        id: "github-actions:1:1",
        repository: "snow/app",
        context: "CI",
        detail: "Running",
        state: .running
    )

    model.replace(
        with: [item],
        isTruncated: true
    )

    #expect(model.items == [item])
    #expect(model.isTruncated)

    model.replace(with: [item])

    #expect(model.items == [item])
    #expect(!model.isTruncated)
}

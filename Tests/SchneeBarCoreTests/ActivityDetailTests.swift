import SchneeBarCore
import Testing

@Test
func activityDetailRowDefaultsToNoChildren() {
    let row = ActivityDetailRow(
        id: "job-1",
        title: "Build",
        state: .success
    )

    #expect(row.children.isEmpty)
}

@Test
func activityDetailRowPreservesChildren() {
    let child = ActivityDetailRow(
        id: "job-2",
        title: "macos-15",
        state: .failed
    )
    let parent = ActivityDetailRow(
        id: "group-1",
        title: "Test",
        detail: "2 variants · 1 failed",
        state: .failed,
        children: [child]
    )

    #expect(parent.children == [child])
    #expect(parent.destinationURL == nil)
}

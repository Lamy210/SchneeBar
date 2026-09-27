@testable import SchneeBarActivityFeature
import SchneeBarCore
import Testing

@Test
func onlyWorkflowRunsSupportLocalDetail() {
    #expect(supportsLocalDetail(kind: .workflowRun))
    #expect(!supportsLocalDetail(kind: .reviewRequest))
    #expect(!supportsLocalDetail(kind: .checkRun))
}

@Test
func truncatedActivityUsesLowNoisePartialStateCopy() throws {
    let presentation = try #require(
        activityPartialStatePresentation(isTruncated: true)
    )

    #expect(
        presentation.text
            == "Showing highest-priority recent activity"
    )
    #expect(
        presentation.accessibilityLabel
            == "Activity list is partial. Showing highest-priority recent activity."
    )
}

@Test
func completeActivityHasNoPartialStatePresentation() {
    #expect(
        activityPartialStatePresentation(isTruncated: false) == nil
    )
}

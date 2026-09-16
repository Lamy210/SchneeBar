@testable import SchneeBarActivityFeature
import SchneeBarCore
import Testing

@Test
func onlyWorkflowRunsSupportLocalDetail() {
    #expect(supportsLocalDetail(kind: .workflowRun))
    #expect(!supportsLocalDetail(kind: .reviewRequest))
    #expect(!supportsLocalDetail(kind: .checkRun))
}

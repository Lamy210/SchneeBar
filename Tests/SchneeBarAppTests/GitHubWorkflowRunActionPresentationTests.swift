@testable import SchneeBar
import SchneeBarCore
import SchneeBarGitHubFeature
import Testing

@Test
func failedWorkflowOffersRerunOnlyWithConfirmedWriteAccess() {
    #expect(
        workflowRunDetailActions(
            for: .failed,
            writeAccess: .available
        ) == [.rerunWorkflow]
    )
    #expect(
        workflowRunDetailActions(
            for: .failed,
            writeAccess: .unverified
        ).isEmpty
    )
    #expect(
        workflowRunDetailActions(
            for: .failed,
            writeAccess: .unavailable
        ).isEmpty
    )
}

@Test
func activeWorkflowOffersCancelOnlyWithConfirmedWriteAccess() {
    #expect(
        workflowRunDetailActions(
            for: .running,
            writeAccess: .available
        ) == [.cancelWorkflow]
    )
    #expect(
        workflowRunDetailActions(
            for: .waiting,
            writeAccess: .available
        ) == [.cancelWorkflow]
    )
}

@Test
func successfulWorkflowOffersRerunWithConfirmedWriteAccess() {
    #expect(
        workflowRunDetailActions(
            for: .success,
            writeAccess: .available
        ) == [.rerunWorkflow]
    )
}

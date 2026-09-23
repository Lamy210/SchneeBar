@testable import SchneeBar
import SchneeBarCore
import SchneeBarGitHub
import Testing

@Test
func workflowWriteCapabilityExposesStateAppropriateAction() {
    #expect(
        workflowDetailActions(
            kind: .workflowRun,
            state: .success,
            writeCapability: .available
        ) == [.rerunWorkflow]
    )
    #expect(
        workflowDetailActions(
            kind: .workflowRun,
            state: .failed,
            writeCapability: .available
        ) == [.rerunWorkflow]
    )
    #expect(
        workflowDetailActions(
            kind: .workflowRun,
            state: .running,
            writeCapability: .available
        ) == [.cancelWorkflow]
    )
    #expect(
        workflowDetailActions(
            kind: .workflowRun,
            state: .waiting,
            writeCapability: .available
        ) == [.cancelWorkflow]
    )
}

@Test
func workflowMutationIsHiddenWhenWriteCapabilityIsNotProven() {
    #expect(
        workflowDetailActions(
            kind: .workflowRun,
            state: .failed,
            writeCapability: .unavailable(.missingPermission)
        ).isEmpty
    )
    #expect(
        workflowDetailActions(
            kind: .workflowRun,
            state: .failed,
            writeCapability: .unknown([.untestedEnterpriseVersion])
        ).isEmpty
    )
    #expect(
        workflowDetailActions(
            kind: .workflowRun,
            state: .failed,
            writeCapability: nil
        ).isEmpty
    )
}

@Test
func nonWorkflowActivityNeverExposesWorkflowMutation() {
    #expect(
        workflowDetailActions(
            kind: .checkRun,
            state: .failed,
            writeCapability: .available
        ).isEmpty
    )
    #expect(
        workflowDetailActions(
            kind: .reviewRequest,
            state: .waiting,
            writeCapability: .available
        ).isEmpty
    )
}

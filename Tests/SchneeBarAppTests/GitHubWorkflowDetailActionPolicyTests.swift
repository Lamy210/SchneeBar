@testable import SchneeBar
import SchneeBarCore
import SchneeBarGitHub
import Testing

@Test(arguments: [
    (ActivityState.success, ActivityDetailAction.rerunWorkflow),
    (.failed, .rerunWorkflow),
    (.running, .cancelWorkflow),
    (.waiting, .cancelWorkflow),
])
func workflowWriteCapabilityExposesStateAppropriateAction(
    state: ActivityState,
    expected: ActivityDetailAction
) {
    #expect(
        workflowDetailActions(
            kind: .workflowRun,
            state: state,
            writeCapability: .available
        ) == [expected]
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

import SchneeBarCore
import SchneeBarGitHub

@MainActor
extension GitHubConnectionsRuntimeModel {
    func performWorkflowRunAction(
        _ action: ActivityDetailAction,
        for item: ActivityItem,
        mutationService: any GitHubWorkflowRunMutating
    ) async throws {
        let context = try workflowActivityContext(for: item)
        let availableActions = workflowRunDetailActions(
            for: item.state,
            writeAccess: workflowWriteAccessPresentation(
                profileID: context.profile.id,
                repositoryID: context.repository.id
            )
        )
        guard availableActions.contains(action) else {
            throw WorkflowRunActionError.unavailable
        }

        switch action {
        case .rerunWorkflow:
            try await mutationService.rerun(
                connection: context.profile.connection,
                identity: context.profile.account,
                clientID: context.profile.clientID,
                repository: context.repository,
                runID: context.runID
            )
        case .cancelWorkflow:
            try await mutationService.cancel(
                connection: context.profile.connection,
                identity: context.profile.account,
                clientID: context.profile.clientID,
                repository: context.repository,
                runID: context.runID
            )
        }

        try Task.checkCancellation()
        onActivitySourceChanged?()
    }
}

enum WorkflowRunActionError: Error, Equatable {
    case unavailable
}

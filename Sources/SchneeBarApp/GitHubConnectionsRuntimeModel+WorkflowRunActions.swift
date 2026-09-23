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
        guard workflowWriteAccessPresentation(
            profileID: context.profile.id,
            repositoryID: context.repository.id
        ) == .available else {
            throw WorkflowRunActionError.unavailable
        }

        do {
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
        } catch GitHubConnectionSessionError.reauthenticationRequired {
            statusByConnectionID[context.profile.id] = .authenticationRequired
            await refreshActivitySourceAfterMutation(
                profileID: context.profile.id
            )
            throw GitHubConnectionSessionError.reauthenticationRequired
        }

        try Task.checkCancellation()
        await refreshActivitySourceAfterMutation(
            profileID: context.profile.id
        )
    }
}

enum WorkflowRunActionError: Error, Equatable {
    case unavailable
}

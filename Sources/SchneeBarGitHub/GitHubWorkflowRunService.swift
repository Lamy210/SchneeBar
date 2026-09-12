import Foundation

public struct GitHubWorkflowRunService: Sendable {
    private let sessionCoordinator: GitHubConnectionSessionCoordinator
    private let actionsClient: GitHubActionsClient

    public init(
        sessionCoordinator: GitHubConnectionSessionCoordinator,
        actionsClient: GitHubActionsClient = GitHubActionsClient()
    ) {
        self.sessionCoordinator = sessionCoordinator
        self.actionsClient = actionsClient
    }

    public func workflowRuns(
        connection: GitHubConnection,
        identity: GitHubAccountIdentity,
        clientID: String?,
        repository: GitHubRepositoryAccess,
        query: GitHubWorkflowRunQuery = .init()
    ) async throws -> [GitHubWorkflowRun] {
        let credential = try await sessionCoordinator.authorizedCredential(
            connection: connection,
            identity: identity,
            clientID: clientID
        )

        return try await actionsClient.workflowRuns(
            repository: repository,
            connection: connection,
            credential: credential,
            query: query
        )
    }
}

import Foundation

public enum GitHubWorkflowRunServiceError: Error, Equatable, Sendable {
    case credentialUnavailableAfterSessionRestore
}

public struct GitHubWorkflowRunService: Sendable {
    private let credentialStore: any GitHubCredentialStore
    private let sessionCoordinator: GitHubConnectionSessionCoordinator
    private let actionsClient: GitHubActionsClient

    public init(
        credentialStore: any GitHubCredentialStore,
        sessionCoordinator: GitHubConnectionSessionCoordinator,
        actionsClient: GitHubActionsClient = GitHubActionsClient()
    ) {
        self.credentialStore = credentialStore
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
        let session = try await sessionCoordinator.restore(
            connection: connection,
            identity: identity,
            clientID: clientID
        )

        guard let credential = try await credentialStore.load(for: session.credentialKey) else {
            throw GitHubWorkflowRunServiceError.credentialUnavailableAfterSessionRestore
        }

        return try await actionsClient.workflowRuns(
            repository: repository,
            connection: connection,
            credential: credential,
            query: query
        )
    }
}

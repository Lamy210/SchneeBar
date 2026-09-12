import Foundation

public protocol GitHubWorkflowJobLoading: Sendable {
    func jobs(
        connection: GitHubConnection,
        identity: GitHubAccountIdentity,
        clientID: String?,
        repository: GitHubRepositoryAccess,
        runID: Int64,
        query: GitHubWorkflowJobQuery
    ) async throws -> [GitHubWorkflowJob]
}

public struct GitHubWorkflowJobService: GitHubWorkflowJobLoading, Sendable {
    private let sessionCoordinator: GitHubConnectionSessionCoordinator
    private let jobsClient: GitHubActionsJobsClient

    public init(
        sessionCoordinator: GitHubConnectionSessionCoordinator,
        jobsClient: GitHubActionsJobsClient = GitHubActionsJobsClient()
    ) {
        self.sessionCoordinator = sessionCoordinator
        self.jobsClient = jobsClient
    }

    public func jobs(
        connection: GitHubConnection,
        identity: GitHubAccountIdentity,
        clientID: String?,
        repository: GitHubRepositoryAccess,
        runID: Int64,
        query: GitHubWorkflowJobQuery = .init()
    ) async throws -> [GitHubWorkflowJob] {
        let credential = try await sessionCoordinator.authorizedCredential(
            connection: connection,
            identity: identity,
            clientID: clientID
        )

        return try await jobsClient.jobs(
            runID: runID,
            repository: repository,
            connection: connection,
            credential: credential,
            query: query
        )
    }
}

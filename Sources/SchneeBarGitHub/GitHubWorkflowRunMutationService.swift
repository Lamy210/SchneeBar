import Foundation

public protocol GitHubWorkflowRunMutating: Sendable {
    func rerun(
        connection: GitHubConnection,
        identity: GitHubAccountIdentity,
        clientID: String?,
        repository: GitHubRepositoryAccess,
        runID: Int64
    ) async throws

    func cancel(
        connection: GitHubConnection,
        identity: GitHubAccountIdentity,
        clientID: String?,
        repository: GitHubRepositoryAccess,
        runID: Int64
    ) async throws
}

public struct GitHubWorkflowRunMutationService:
    GitHubWorkflowRunMutating,
    Sendable
{
    private let sessionCoordinator: GitHubConnectionSessionCoordinator
    private let client: GitHubWorkflowRunMutationClient

    public init(
        sessionCoordinator: GitHubConnectionSessionCoordinator,
        client: GitHubWorkflowRunMutationClient = GitHubWorkflowRunMutationClient()
    ) {
        self.sessionCoordinator = sessionCoordinator
        self.client = client
    }

    public func rerun(
        connection: GitHubConnection,
        identity: GitHubAccountIdentity,
        clientID: String?,
        repository: GitHubRepositoryAccess,
        runID: Int64
    ) async throws {
        let credential = try await sessionCoordinator.authorizedCredential(
            connection: connection,
            identity: identity,
            clientID: clientID
        )
        do {
            try await client.rerun(
                runID: runID,
                repository: repository,
                connection: connection,
                credential: credential
            )
        } catch let error as GitHubWorkflowRunMutationError
            where error.statusCode == 401
        {
            throw GitHubConnectionSessionError.reauthenticationRequired
        } catch let GitHubWorkflowRunMutationError.httpFailure(evidence)
            where evidence.statusCode == 403
                && evidence.ssoSignal == .required
        {
            throw GitHubConnectionSessionError.ssoRequired
        }
    }

    public func cancel(
        connection: GitHubConnection,
        identity: GitHubAccountIdentity,
        clientID: String?,
        repository: GitHubRepositoryAccess,
        runID: Int64
    ) async throws {
        let credential = try await sessionCoordinator.authorizedCredential(
            connection: connection,
            identity: identity,
            clientID: clientID
        )
        do {
            try await client.cancel(
                runID: runID,
                repository: repository,
                connection: connection,
                credential: credential
            )
        } catch let error as GitHubWorkflowRunMutationError
            where error.statusCode == 401
        {
            throw GitHubConnectionSessionError.reauthenticationRequired
        } catch let GitHubWorkflowRunMutationError.httpFailure(evidence)
            where evidence.statusCode == 403
                && evidence.ssoSignal == .required
        {
            throw GitHubConnectionSessionError.ssoRequired
        }
    }
}

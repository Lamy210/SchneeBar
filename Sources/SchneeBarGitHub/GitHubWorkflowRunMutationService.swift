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
    private let mutationClient: GitHubWorkflowRunMutationClient

    public init(
        sessionCoordinator: GitHubConnectionSessionCoordinator,
        mutationClient: GitHubWorkflowRunMutationClient =
            GitHubWorkflowRunMutationClient()
    ) {
        self.sessionCoordinator = sessionCoordinator
        self.mutationClient = mutationClient
    }

    public func rerun(
        connection: GitHubConnection,
        identity: GitHubAccountIdentity,
        clientID: String?,
        repository: GitHubRepositoryAccess,
        runID: Int64
    ) async throws {
        let credential = try await authorizedCredential(
            connection: connection,
            identity: identity,
            clientID: clientID
        )
        try Task.checkCancellation()
        do {
            try await mutationClient.rerun(
                runID: runID,
                repository: repository,
                connection: connection,
                credential: credential
            )
        } catch GitHubWorkflowRunMutationError.httpStatus(401) {
            throw GitHubConnectionSessionError.reauthenticationRequired
        }
    }

    public func cancel(
        connection: GitHubConnection,
        identity: GitHubAccountIdentity,
        clientID: String?,
        repository: GitHubRepositoryAccess,
        runID: Int64
    ) async throws {
        let credential = try await authorizedCredential(
            connection: connection,
            identity: identity,
            clientID: clientID
        )
        try Task.checkCancellation()
        do {
            try await mutationClient.cancel(
                runID: runID,
                repository: repository,
                connection: connection,
                credential: credential
            )
        } catch GitHubWorkflowRunMutationError.httpStatus(401) {
            throw GitHubConnectionSessionError.reauthenticationRequired
        }
    }

    private func authorizedCredential(
        connection: GitHubConnection,
        identity: GitHubAccountIdentity,
        clientID: String?
    ) async throws -> GitHubCredential {
        try await sessionCoordinator.authorizedCredential(
            connection: connection,
            identity: identity,
            clientID: clientID
        )
    }
}

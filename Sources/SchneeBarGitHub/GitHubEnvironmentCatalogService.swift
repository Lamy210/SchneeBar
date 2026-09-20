import Foundation

public protocol GitHubEnvironmentCatalogLoading: Sendable {
    func environmentCatalog(
        connection: GitHubConnection,
        identity: GitHubAccountIdentity,
        clientID: String?,
        repository: GitHubRepositoryAccess
    ) async throws -> GitHubEnvironmentCatalog
}

public struct GitHubEnvironmentCatalogService:
    GitHubEnvironmentCatalogLoading,
    Sendable
{
    private let sessionCoordinator: GitHubConnectionSessionCoordinator
    private let environmentClient: GitHubEnvironmentClient

    public init(
        sessionCoordinator: GitHubConnectionSessionCoordinator,
        environmentClient: GitHubEnvironmentClient = .init()
    ) {
        self.sessionCoordinator = sessionCoordinator
        self.environmentClient = environmentClient
    }

    public func environmentCatalog(
        connection: GitHubConnection,
        identity: GitHubAccountIdentity,
        clientID: String?,
        repository: GitHubRepositoryAccess
    ) async throws -> GitHubEnvironmentCatalog {
        let credential = try await sessionCoordinator.authorizedCredential(
            connection: connection,
            identity: identity,
            clientID: clientID
        )

        try Task.checkCancellation()

        return try await environmentClient.environments(
            repository: repository,
            connection: connection,
            credential: credential,
            limit: 100
        )
    }
}

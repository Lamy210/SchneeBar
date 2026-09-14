import Foundation

public protocol GitHubPullRequestMetadataLoading: Sendable {
    func pullRequest(
        number: Int,
        connection: GitHubConnection,
        identity: GitHubAccountIdentity,
        clientID: String?,
        repository: GitHubRepositoryAccess
    ) async throws -> GitHubPullRequestMetadata
}

public struct GitHubPullRequestMetadataService: GitHubPullRequestMetadataLoading, Sendable {
    private let sessionCoordinator: GitHubConnectionSessionCoordinator
    private let metadataClient: GitHubPullRequestMetadataClient

    public init(
        sessionCoordinator: GitHubConnectionSessionCoordinator,
        metadataClient: GitHubPullRequestMetadataClient = GitHubPullRequestMetadataClient()
    ) {
        self.sessionCoordinator = sessionCoordinator
        self.metadataClient = metadataClient
    }

    public func pullRequest(
        number: Int,
        connection: GitHubConnection,
        identity: GitHubAccountIdentity,
        clientID: String?,
        repository: GitHubRepositoryAccess
    ) async throws -> GitHubPullRequestMetadata {
        let credential = try await sessionCoordinator.authorizedCredential(
            connection: connection,
            identity: identity,
            clientID: clientID
        )

        return try await metadataClient.pullRequest(
            number: number,
            repository: repository,
            connection: connection,
            credential: credential
        )
    }
}

public protocol GitHubReviewRequestLoading: Sendable {
    func reviewRequests(
        connection: GitHubConnection,
        identity: GitHubAccountIdentity,
        clientID: String?,
        repository: GitHubRepositoryAccess
    ) async throws -> [GitHubReviewRequest]
}

public struct GitHubReviewRequestService: GitHubReviewRequestLoading, Sendable {
    private let sessionCoordinator: GitHubConnectionSessionCoordinator
    private let client: GitHubPullRequestListClient

    public init(
        sessionCoordinator: GitHubConnectionSessionCoordinator,
        client: GitHubPullRequestListClient = GitHubPullRequestListClient()
    ) {
        self.sessionCoordinator = sessionCoordinator
        self.client = client
    }

    public func reviewRequests(
        connection: GitHubConnection,
        identity: GitHubAccountIdentity,
        clientID: String?,
        repository: GitHubRepositoryAccess
    ) async throws -> [GitHubReviewRequest] {
        let credential = try await sessionCoordinator.authorizedCredential(
            connection: connection,
            identity: identity,
            clientID: clientID
        )
        return try await client.openPullRequests(
            repository: repository,
            connection: connection,
            credential: credential
        )
    }
}

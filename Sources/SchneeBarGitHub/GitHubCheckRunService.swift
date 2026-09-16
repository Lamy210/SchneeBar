public protocol GitHubCheckRunLoading: Sendable {
    func checkRuns(
        connection: GitHubConnection,
        identity: GitHubAccountIdentity,
        clientID: String?,
        repository: GitHubRepositoryAccess,
        headSHA: String
    ) async throws -> [GitHubCheckRun]
}

public struct GitHubCheckRunService: GitHubCheckRunLoading, Sendable {
    private let sessionCoordinator: GitHubConnectionSessionCoordinator
    private let client: GitHubCheckRunClient

    public init(
        sessionCoordinator: GitHubConnectionSessionCoordinator,
        client: GitHubCheckRunClient = GitHubCheckRunClient()
    ) {
        self.sessionCoordinator = sessionCoordinator
        self.client = client
    }

    public func checkRuns(
        connection: GitHubConnection,
        identity: GitHubAccountIdentity,
        clientID: String?,
        repository: GitHubRepositoryAccess,
        headSHA: String
    ) async throws -> [GitHubCheckRun] {
        let credential = try await sessionCoordinator.authorizedCredential(
            connection: connection,
            identity: identity,
            clientID: clientID
        )
        return try await client.checkRuns(
            repository: repository,
            headSHA: headSHA,
            connection: connection,
            credential: credential
        )
    }
}

import SchneeBarGitHub

struct EmptyAppReviewRequestLoader: GitHubReviewRequestLoading {
    func reviewRequests(
        connection: GitHubConnection,
        identity: GitHubAccountIdentity,
        clientID: String?,
        repository: GitHubRepositoryAccess
    ) async throws -> [GitHubReviewRequest] {
        []
    }
}

struct EmptyAppCheckRunLoader: GitHubCheckRunLoading {
    func checkRuns(
        connection: GitHubConnection,
        identity: GitHubAccountIdentity,
        clientID: String?,
        repository: GitHubRepositoryAccess,
        headSHA: String
    ) async throws -> [GitHubCheckRun] {
        []
    }
}

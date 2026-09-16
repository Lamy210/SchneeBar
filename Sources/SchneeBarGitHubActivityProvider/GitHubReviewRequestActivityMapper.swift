import SchneeBarCore
import SchneeBarGitHub

public struct GitHubReviewRequestActivityMapper: Sendable {
    public init() {}

    public func visibleRequests(
        requests: [GitHubReviewRequest],
        identity: GitHubAccountIdentity
    ) -> [GitHubReviewRequest] {
        requests
            .filter { $0.requestedReviewerIDs.contains(identity.id) }
            .sorted { lhs, rhs in
                if lhs.updatedAt != rhs.updatedAt {
                    return lhs.updatedAt > rhs.updatedAt
                }
                return lhs.number < rhs.number
            }
    }

    public func activityItem(
        request: GitHubReviewRequest,
        repository: GitHubRepositoryAccess
    ) -> ActivityItem {
        ActivityItem(
            id: "github-review:\(repository.id):\(request.number)",
            repository: repository.fullName,
            context: "PR #\(request.number)",
            detail: "Review requested · \(request.title)",
            state: .waiting,
            destinationURL: request.webURL,
            kind: .reviewRequest,
            attention: .actionRequired,
            updatedAt: request.updatedAt
        )
    }
}

import SchneeBarCore

public struct GitHubActivityCachePolicy: Equatable, Sendable {
    public let maximumWorkflowRepositories: Int
    public let maximumReviewRepositories: Int
    public let maximumCheckTargets: Int
    public let maximumRecoveryLanesPerRepository: Int
    public let maximumRetainedItemsPerSurface: Int
    public let maximumRetainedFailuresPerSurface: Int

    public init(
        maximumWorkflowRepositories: Int = 20,
        maximumReviewRepositories: Int = 20,
        maximumCheckTargets: Int = 20,
        maximumRecoveryLanesPerRepository: Int = 100,
        maximumRetainedItemsPerSurface: Int =
            ActivitySourceCollectionPolicy.maximumItemsPerSource,
        maximumRetainedFailuresPerSurface: Int =
            ActivitySourceCollectionPolicy.maximumItemsPerSource
    ) {
        self.maximumWorkflowRepositories = max(
            1,
            maximumWorkflowRepositories
        )
        self.maximumReviewRepositories = max(
            1,
            maximumReviewRepositories
        )
        self.maximumCheckTargets = max(
            1,
            maximumCheckTargets
        )
        self.maximumRecoveryLanesPerRepository = max(
            1,
            maximumRecoveryLanesPerRepository
        )
        self.maximumRetainedItemsPerSurface = max(
            1,
            maximumRetainedItemsPerSurface
        )
        self.maximumRetainedFailuresPerSurface = max(
            1,
            maximumRetainedFailuresPerSurface
        )
    }
}

public enum GitHubActionsAccess: Equatable, Sendable {
    case available
    case unverified
    case unavailable
}

public struct GitHubActionsAccessSummary: Equatable, Sendable {
    public let accessByRepositoryID: [Int64: GitHubActionsAccess]
    public let unverifiedRepositoryCount: Int
    public let unavailableRepositoryCount: Int

    public init(
        accessByRepositoryID: [Int64: GitHubActionsAccess],
        unverifiedRepositoryCount: Int,
        unavailableRepositoryCount: Int
    ) {
        self.accessByRepositoryID = accessByRepositoryID
        self.unverifiedRepositoryCount = unverifiedRepositoryCount
        self.unavailableRepositoryCount = unavailableRepositoryCount
    }

    public static func evaluate(
        repositoryIDs: Set<Int64>,
        assessment: GitHubConnectionCapabilityAssessment?
    ) -> GitHubActionsAccessSummary {
        var accessByRepositoryID: [Int64: GitHubActionsAccess] = [:]
        var unverifiedRepositoryCount = 0
        var unavailableRepositoryCount = 0

        for repositoryID in repositoryIDs {
            let access: GitHubActionsAccess
            switch assessment?.state(for: .actions, repositoryID: repositoryID) {
            case .available:
                access = .available
            case .unavailable:
                access = .unavailable
                unavailableRepositoryCount += 1
            case .unknown, nil:
                access = .unverified
                unverifiedRepositoryCount += 1
            }
            accessByRepositoryID[repositoryID] = access
        }

        return GitHubActionsAccessSummary(
            accessByRepositoryID: accessByRepositoryID,
            unverifiedRepositoryCount: unverifiedRepositoryCount,
            unavailableRepositoryCount: unavailableRepositoryCount
        )
    }
}

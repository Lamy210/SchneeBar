import SchneeBarCore

public enum GitHubActivitySurface: String, CaseIterable, Hashable, Sendable {
    case workflows
    case reviewRequests
    case checks
}

public struct GitHubActivityTargetFailure: Equatable, Sendable {
    public let surface: GitHubActivitySurface
    public let repositoryID: Int64
    public let repositoryFullName: String
    public let reason: GitHubRepositoryActivityFailureReason

    public init(
        surface: GitHubActivitySurface,
        repositoryID: Int64,
        repositoryFullName: String,
        reason: GitHubRepositoryActivityFailureReason
    ) {
        self.surface = surface
        self.repositoryID = repositoryID
        self.repositoryFullName = repositoryFullName
        self.reason = reason
    }
}

public struct GitHubActivitySurfaceResult: Equatable, Sendable {
    public let surface: GitHubActivitySurface
    public let items: [ActivityItem]
    public let failures: [GitHubActivityTargetFailure]
    public let successfulTargetCount: Int
    public let attemptedTargetCount: Int
    public let blockedTargetCount: Int

    public var consideredTargetCount: Int {
        attemptedTargetCount + blockedTargetCount
    }

    public init(
        surface: GitHubActivitySurface,
        items: [ActivityItem],
        failures: [GitHubActivityTargetFailure],
        successfulTargetCount: Int,
        attemptedTargetCount: Int,
        blockedTargetCount: Int
    ) {
        self.surface = surface
        self.items = items
        self.failures = failures.sorted(by: Self.failureSort)
        self.successfulTargetCount = max(0, successfulTargetCount)
        self.attemptedTargetCount = max(0, attemptedTargetCount)
        self.blockedTargetCount = max(0, blockedTargetCount)
    }

    public static func empty(_ surface: GitHubActivitySurface) -> GitHubActivitySurfaceResult {
        GitHubActivitySurfaceResult(
            surface: surface,
            items: [],
            failures: [],
            successfulTargetCount: 0,
            attemptedTargetCount: 0,
            blockedTargetCount: 0
        )
    }

    private static func failureSort(
        lhs: GitHubActivityTargetFailure,
        rhs: GitHubActivityTargetFailure
    ) -> Bool {
        if lhs.repositoryID != rhs.repositoryID {
            return lhs.repositoryID < rhs.repositoryID
        }
        if lhs.repositoryFullName != rhs.repositoryFullName {
            return lhs.repositoryFullName < rhs.repositoryFullName
        }
        let lhsRank = failureReasonRank(lhs.reason)
        let rhsRank = failureReasonRank(rhs.reason)
        if lhsRank != rhsRank {
            return lhsRank < rhsRank
        }
        return lhs.surface.rawValue < rhs.surface.rawValue
    }

    private static func failureReasonRank(
        _ reason: GitHubRepositoryActivityFailureReason
    ) -> Int {
        switch reason {
        case .authenticationRequired: 0
        case .forbidden: 1
        case .notFound: 2
        case .networkUnavailable: 3
        case .unavailable: 4
        case .capabilityUnavailable: 5
        }
    }
}

import SchneeBarCore

public enum GitHubRepositoryActivityFailureReason: Equatable, Sendable {
    case authenticationRequired
    case forbidden
    case notFound
    case networkUnavailable
    case unavailable
    case capabilityUnavailable
}

public struct GitHubRepositoryActivityFailure: Equatable, Sendable {
    public let repositoryID: Int64
    public let repositoryFullName: String
    public let reason: GitHubRepositoryActivityFailureReason

    public init(
        repositoryID: Int64,
        repositoryFullName: String,
        reason: GitHubRepositoryActivityFailureReason
    ) {
        self.repositoryID = repositoryID
        self.repositoryFullName = repositoryFullName
        self.reason = reason
    }
}

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
        self.items = items.sorted(by: ActivityInboxOrdering().areInIncreasingOrder)
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

public struct GitHubActivityLoadResult: Equatable, Sendable {
    public let items: [ActivityItem]
    public let surfaces: [GitHubActivitySurface: GitHubActivitySurfaceResult]

    public init(
        items: [ActivityItem],
        surfaces: [GitHubActivitySurface: GitHubActivitySurfaceResult]
    ) {
        var normalized = surfaces
        for surface in GitHubActivitySurface.allCases where normalized[surface] == nil {
            normalized[surface] = .empty(surface)
        }
        self.surfaces = normalized
        self.items = items.sorted(by: ActivityInboxOrdering().areInIncreasingOrder)
    }

    public init(surfaces: [GitHubActivitySurface: GitHubActivitySurfaceResult]) {
        self.init(
            items: GitHubActivitySurface.allCases.flatMap {
                surfaces[$0]?.items ?? []
            },
            surfaces: surfaces
        )
    }

    public func surface(_ surface: GitHubActivitySurface) -> GitHubActivitySurfaceResult {
        surfaces[surface] ?? .empty(surface)
    }

    public var targetFailures: [GitHubActivityTargetFailure] {
        GitHubActivitySurface.allCases.flatMap { surface($0).failures }
    }

    /// Compatibility projection for callers that still consume repository-level failures.
    /// Surface identity remains available through `targetFailures` and `surface(_:)`.
    public var failures: [GitHubRepositoryActivityFailure] {
        targetFailures.map {
            GitHubRepositoryActivityFailure(
                repositoryID: $0.repositoryID,
                repositoryFullName: $0.repositoryFullName,
                reason: $0.reason
            )
        }
    }

    public var successfulTargetCount: Int {
        GitHubActivitySurface.allCases.reduce(0) { $0 + surface($1).successfulTargetCount }
    }

    public var attemptedTargetCount: Int {
        GitHubActivitySurface.allCases.reduce(0) { $0 + surface($1).attemptedTargetCount }
    }

    public var blockedTargetCount: Int {
        GitHubActivitySurface.allCases.reduce(0) { $0 + surface($1).blockedTargetCount }
    }

    public var consideredTargetCount: Int {
        attemptedTargetCount + blockedTargetCount
    }

    // Workflow-only compatibility aliases used while App/runtime consumers migrate to surfaces.
    public var successfulRepositoryCount: Int {
        surface(.workflows).successfulTargetCount
    }

    public var attemptedRepositoryCount: Int {
        surface(.workflows).attemptedTargetCount
    }

    public var blockedRepositoryCount: Int {
        surface(.workflows).blockedTargetCount
    }

    public var consideredRepositoryCount: Int {
        surface(.workflows).consideredTargetCount
    }

    public init(
        items: [ActivityItem],
        failures: [GitHubRepositoryActivityFailure],
        successfulRepositoryCount: Int,
        attemptedRepositoryCount: Int,
        blockedRepositoryCount: Int = 0
    ) {
        let workflowFailures = failures.map {
            GitHubActivityTargetFailure(
                surface: .workflows,
                repositoryID: $0.repositoryID,
                repositoryFullName: $0.repositoryFullName,
                reason: $0.reason
            )
        }
        self.init(
            surfaces: [
                .workflows: GitHubActivitySurfaceResult(
                    surface: .workflows,
                    items: items,
                    failures: workflowFailures,
                    successfulTargetCount: successfulRepositoryCount,
                    attemptedTargetCount: attemptedRepositoryCount,
                    blockedTargetCount: blockedRepositoryCount
                ),
            ]
        )
    }

    public static var empty: GitHubActivityLoadResult {
        GitHubActivityLoadResult(surfaces: [:])
    }
}

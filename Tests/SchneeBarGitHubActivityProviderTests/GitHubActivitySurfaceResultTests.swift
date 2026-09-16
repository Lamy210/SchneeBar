import SchneeBarCore
import SchneeBarGitHubActivityProvider
import Testing

@Test
func surfaceResultsPreserveSourceIdentityForSameRepository() {
    let workflow = GitHubActivitySurfaceResult(
        surface: .workflows,
        items: [activityItem(id: "workflow")],
        failures: [],
        successfulTargetCount: 1,
        attemptedTargetCount: 1,
        blockedTargetCount: 0
    )
    let review = GitHubActivitySurfaceResult(
        surface: .reviewRequests,
        items: [],
        failures: [
            GitHubActivityTargetFailure(
                surface: .reviewRequests,
                repositoryID: 42,
                repositoryFullName: "snow-labs/frost",
                reason: .forbidden
            ),
        ],
        successfulTargetCount: 0,
        attemptedTargetCount: 1,
        blockedTargetCount: 0
    )
    let checks = GitHubActivitySurfaceResult(
        surface: .checks,
        items: [],
        failures: [
            GitHubActivityTargetFailure(
                surface: .checks,
                repositoryID: 42,
                repositoryFullName: "snow-labs/frost",
                reason: .capabilityUnavailable
            ),
        ],
        successfulTargetCount: 0,
        attemptedTargetCount: 0,
        blockedTargetCount: 1
    )

    let result = GitHubActivityLoadResult(
        items: workflow.items,
        surfaces: [
            .workflows: workflow,
            .reviewRequests: review,
            .checks: checks,
        ]
    )

    #expect(result.surface(.workflows) == workflow)
    #expect(result.surface(.reviewRequests) == review)
    #expect(result.surface(.checks) == checks)
    #expect(result.successfulTargetCount == 1)
    #expect(result.attemptedTargetCount == 2)
    #expect(result.blockedTargetCount == 1)
    #expect(result.consideredTargetCount == 3)
    #expect(result.failures.map(\.surface) == [.reviewRequests, .checks])
}

@Test
func aggregateFailuresHaveDeterministicSurfaceAndRepositoryOrder() {
    let checks = GitHubActivitySurfaceResult(
        surface: .checks,
        items: [],
        failures: [
            GitHubActivityTargetFailure(surface: .checks, repositoryID: 2, repositoryFullName: "snow/beta", reason: .notFound),
            GitHubActivityTargetFailure(surface: .checks, repositoryID: 1, repositoryFullName: "snow/alpha", reason: .forbidden),
        ],
        successfulTargetCount: 0,
        attemptedTargetCount: 2,
        blockedTargetCount: 0
    )
    let workflow = GitHubActivitySurfaceResult(
        surface: .workflows,
        items: [],
        failures: [
            GitHubActivityTargetFailure(surface: .workflows, repositoryID: 9, repositoryFullName: "snow/zeta", reason: .unavailable),
        ],
        successfulTargetCount: 0,
        attemptedTargetCount: 1,
        blockedTargetCount: 0
    )

    let result = GitHubActivityLoadResult(
        items: [],
        surfaces: [.checks: checks, .workflows: workflow]
    )

    #expect(result.failures.map { ($0.surface, $0.repositoryID) } == [
        (.workflows, 9),
        (.checks, 1),
        (.checks, 2),
    ])
}

private func activityItem(id: String) -> ActivityItem {
    ActivityItem(
        id: id,
        repository: "snow-labs/frost",
        context: "main · CI",
        detail: "Running",
        state: .running,
        kind: .workflowRun,
        attention: .active
    )
}

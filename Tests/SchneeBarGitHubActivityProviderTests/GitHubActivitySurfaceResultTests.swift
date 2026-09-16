import SchneeBarCore
import SchneeBarGitHubActivityProvider
import Testing

@Test
func surfaceResultsPreserveSourceIdentityAndCounts() {
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

    #expect(workflow.surface == .workflows)
    #expect(workflow.successfulTargetCount == 1)
    #expect(workflow.attemptedTargetCount == 1)
    #expect(workflow.blockedTargetCount == 0)
    #expect(review.failures.first?.surface == .reviewRequests)
    #expect(checks.failures.first?.surface == .checks)
    #expect(checks.blockedTargetCount == 1)
}

@Test
func surfaceResultSortsFailuresDeterministicallyInsideSource() {
    let checks = GitHubActivitySurfaceResult(
        surface: .checks,
        items: [],
        failures: [
            GitHubActivityTargetFailure(surface: .checks, repositoryID: 2, repositoryFullName: "snow/beta", reason: .notFound),
            GitHubActivityTargetFailure(surface: .checks, repositoryID: 1, repositoryFullName: "snow/alpha", reason: .forbidden),
            GitHubActivityTargetFailure(surface: .checks, repositoryID: 1, repositoryFullName: "snow/alpha", reason: .authenticationRequired),
        ],
        successfulTargetCount: 0,
        attemptedTargetCount: 3,
        blockedTargetCount: 0
    )

    #expect(checks.failures.map(\.repositoryID) == [1, 1, 2])
    #expect(checks.failures.map(\.reason) == [
        .authenticationRequired,
        .forbidden,
        .notFound,
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

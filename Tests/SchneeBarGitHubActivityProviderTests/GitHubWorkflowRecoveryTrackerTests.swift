import Foundation
import SchneeBarCore
import SchneeBarGitHub
import SchneeBarGitHubActivityProvider
import Testing

@Test
func recoveryTrackerColdFailureArmsWithoutEmitting() throws {
    var tracker = GitHubWorkflowRecoveryTracker()
    let events = tracker.observe(
        runs: [try recoveryRun(id: 100, runNumber: 10, conclusion: .failure)],
        repository: try recoveryRepository()
    )

    #expect(events.isEmpty)
}

@Test
func recoveryTrackerColdSuccessDoesNotEmitHistoricalRecovery() throws {
    var tracker = GitHubWorkflowRecoveryTracker()
    let events = tracker.observe(
        runs: [try recoveryRun(id: 101, runNumber: 11, conclusion: .success)],
        repository: try recoveryRepository()
    )

    #expect(events.isEmpty)
}

@Test
func recoveryTrackerFailureThenNewerSuccessEmitsExactlyOnce() throws {
    var tracker = GitHubWorkflowRecoveryTracker()
    let repository = try recoveryRepository()

    #expect(
        tracker.observe(
            runs: [try recoveryRun(id: 100, runNumber: 10, conclusion: .failure)],
            repository: repository
        ).isEmpty
    )

    let first = tracker.observe(
        runs: [try recoveryRun(id: 101, runNumber: 11, conclusion: .success)],
        repository: repository
    )
    let repeated = tracker.observe(
        runs: [try recoveryRun(id: 101, runNumber: 11, conclusion: .success)],
        repository: repository
    )

    #expect(first.count == 1)
    #expect(first[0].repository == "acme/app")
    #expect(first[0].title == "CI recovered")
    #expect(
        first[0].detail
            == "PR #120 succeeded after a previously observed failed workflow run"
    )
    #expect(first[0].destinationURL?.absoluteString == "https://github.com/acme/app/actions/runs/101")
    #expect(repeated.isEmpty)
}

@Test
func recoveryTrackerRunningAndIgnoredRunsPreserveArmedFailure() throws {
    var tracker = GitHubWorkflowRecoveryTracker()
    let repository = try recoveryRepository()

    _ = tracker.observe(
        runs: [try recoveryRun(id: 100, runNumber: 10, conclusion: .failure)],
        repository: repository
    )
    #expect(
        tracker.observe(
            runs: [
                try recoveryRun(
                    id: 101,
                    runNumber: 11,
                    status: .inProgress,
                    conclusion: nil
                ),
            ],
            repository: repository
        ).isEmpty
    )
    #expect(
        tracker.observe(
            runs: [try recoveryRun(id: 102, runNumber: 12, conclusion: .cancelled)],
            repository: repository
        ).isEmpty
    )

    let recovered = tracker.observe(
        runs: [try recoveryRun(id: 103, runNumber: 13, conclusion: .success)],
        repository: repository
    )

    #expect(recovered.count == 1)
}

@Test
func recoveryTrackerSameRunFailureToSuccessEmitsOnce() throws {
    var tracker = GitHubWorkflowRecoveryTracker()
    let repository = try recoveryRepository()

    _ = tracker.observe(
        runs: [try recoveryRun(id: 100, runNumber: 10, conclusion: .failure, updatedAt: 100)],
        repository: repository
    )
    let recovered = tracker.observe(
        runs: [try recoveryRun(id: 100, runNumber: 10, conclusion: .success, updatedAt: 200)],
        repository: repository
    )

    #expect(recovered.count == 1)
    #expect(recovered[0].id.contains(":100"))
}

@Test
func recoveryTrackerNewerFailureRearmsAfterRecovery() throws {
    var tracker = GitHubWorkflowRecoveryTracker()
    let repository = try recoveryRepository()

    _ = tracker.observe(
        runs: [try recoveryRun(id: 100, runNumber: 10, conclusion: .failure)],
        repository: repository
    )
    #expect(
        tracker.observe(
            runs: [try recoveryRun(id: 101, runNumber: 11, conclusion: .success)],
            repository: repository
        ).count == 1
    )
    #expect(
        tracker.observe(
            runs: [try recoveryRun(id: 102, runNumber: 12, conclusion: .failure)],
            repository: repository
        ).isEmpty
    )

    let second = tracker.observe(
        runs: [try recoveryRun(id: 103, runNumber: 13, conclusion: .success)],
        repository: repository
    )
    #expect(second.count == 1)
    #expect(second[0].id != "github-delivery-recovery:42:41:pull_request:120:101")
}

@Test
func recoveryTrackerOlderObservationDoesNotRollStateBackward() throws {
    var tracker = GitHubWorkflowRecoveryTracker()
    let repository = try recoveryRepository()

    _ = tracker.observe(
        runs: [try recoveryRun(id: 101, runNumber: 11, conclusion: .failure)],
        repository: repository
    )
    #expect(
        tracker.observe(
            runs: [try recoveryRun(id: 99, runNumber: 9, conclusion: .success)],
            repository: repository
        ).isEmpty
    )

    let recovered = tracker.observe(
        runs: [try recoveryRun(id: 102, runNumber: 12, conclusion: .success)],
        repository: repository
    )
    #expect(recovered.count == 1)
}

@Test
func recoveryTrackerRejectsAmbiguousPullRequestIdentityAndKeepsLanesIsolated() throws {
    var tracker = GitHubWorkflowRecoveryTracker()
    let repository = try recoveryRepository()

    _ = tracker.observe(
        runs: [
            try recoveryRun(id: 100, runNumber: 10, conclusion: .failure, pullRequests: []),
            try recoveryRun(id: 101, runNumber: 10, conclusion: .failure, pullRequests: [120, 121]),
            try recoveryRun(id: 102, workflowID: 41, runNumber: 10, conclusion: .failure, pullRequests: [120]),
            try recoveryRun(id: 103, workflowID: 42, runNumber: 10, conclusion: .failure, pullRequests: [120]),
            try recoveryRun(id: 104, workflowID: 41, event: "pull_request_target", runNumber: 10, conclusion: .failure, pullRequests: [120]),
        ],
        repository: repository
    )

    let events = tracker.observe(
        runs: [
            try recoveryRun(id: 110, runNumber: 11, conclusion: .success, pullRequests: []),
            try recoveryRun(id: 111, runNumber: 11, conclusion: .success, pullRequests: [120, 121]),
            try recoveryRun(id: 112, workflowID: 41, runNumber: 11, conclusion: .success, pullRequests: [120]),
            try recoveryRun(id: 113, workflowID: 42, runNumber: 11, conclusion: .success, pullRequests: [120]),
            try recoveryRun(id: 114, workflowID: 41, event: "pull_request_target", runNumber: 11, conclusion: .success, pullRequests: [120]),
        ],
        repository: repository
    )

    #expect(events.count == 3)
    #expect(Set(events.map(\.id)).count == 3)
}

@Test
func recoveryTrackerExplanationNeverContainsRawSHA() throws {
    var tracker = GitHubWorkflowRecoveryTracker()
    let repository = try recoveryRepository()

    _ = tracker.observe(
        runs: [
            try recoveryRun(
                id: 100,
                runNumber: 10,
                headSHA: "sensitive-failed-sha",
                conclusion: .failure
            ),
        ],
        repository: repository
    )
    let events = tracker.observe(
        runs: [
            try recoveryRun(
                id: 101,
                runNumber: 11,
                headSHA: "sensitive-success-sha",
                conclusion: .success
            ),
        ],
        repository: repository
    )

    let text = events.flatMap {
        [$0.id, $0.repository, $0.title, $0.detail, $0.destinationURL?.absoluteString ?? ""]
    }.joined(separator: " ")
    #expect(!text.contains("sensitive-failed-sha"))
    #expect(!text.contains("sensitive-success-sha"))
}

private func recoveryRun(
    id: Int64,
    workflowID: Int64 = 41,
    event: String = "pull_request",
    runNumber: Int,
    headSHA: String = "head-sha",
    status: GitHubWorkflowRunStatus = .completed,
    conclusion: GitHubWorkflowRunConclusion?,
    pullRequests: [Int] = [120],
    updatedAt: TimeInterval? = nil
) throws -> GitHubWorkflowRun {
    let timestamp = updatedAt ?? TimeInterval(runNumber * 10)
    return GitHubWorkflowRun(
        id: id,
        workflowID: workflowID,
        name: "CI",
        displayTitle: "Build",
        event: event,
        status: status,
        conclusion: conclusion,
        runNumber: runNumber,
        headBranch: "feature",
        headSHA: headSHA,
        webURL: try #require(URL(string: "https://github.com/acme/app/actions/runs/\(id)")),
        pullRequestNumbers: pullRequests,
        createdAt: Date(timeIntervalSince1970: timestamp - 5),
        updatedAt: Date(timeIntervalSince1970: timestamp)
    )
}

private func recoveryRepository() throws -> GitHubRepositoryAccess {
    GitHubRepositoryAccess(
        id: 42,
        name: "app",
        fullName: "acme/app",
        isPrivate: true,
        webURL: try #require(URL(string: "https://github.com/acme/app")),
        ownerLogin: "acme",
        permissions: GitHubRepositoryPermissions(pull: true),
        defaultBranch: "main"
    )
}

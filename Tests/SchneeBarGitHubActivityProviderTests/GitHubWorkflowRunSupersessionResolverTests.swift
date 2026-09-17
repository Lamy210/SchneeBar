import Foundation
import SchneeBarGitHub
import SchneeBarGitHubActivityProvider
import Testing

@Test
func supersedesOlderDifferentSHAInSamePullRequestLane() throws {
    let old = try supersessionRun(id: 80, runNumber: 80, headSHA: "AAA", updatedAt: 100)
    let current = try supersessionRun(id: 81, runNumber: 81, headSHA: "bbb", updatedAt: 200)

    let result = GitHubWorkflowRunSupersessionResolver().resolve(runs: [old, current])

    #expect(result.supersededRunIDs == Set([80]))
    #expect(result.currentRuns.map(\.id) == [81])
}

@Test
func newestCancelledRunStillSupersedesOlderDifferentSHA() throws {
    let old = try supersessionRun(
        id: 80,
        runNumber: 80,
        headSHA: "aaa",
        updatedAt: 100,
        status: .completed,
        conclusion: .failure
    )
    let current = try supersessionRun(
        id: 81,
        runNumber: 81,
        headSHA: "bbb",
        updatedAt: 200,
        status: .completed,
        conclusion: .cancelled
    )

    let result = GitHubWorkflowRunSupersessionResolver().resolve(runs: [old, current])

    #expect(result.supersededRunIDs == Set([80]))
    #expect(result.currentRuns.map(\.id) == [81])
}

@Test
func sameSHAKeepsBothRuns() throws {
    let old = try supersessionRun(id: 80, runNumber: 80, headSHA: "aaa", updatedAt: 100)
    let current = try supersessionRun(id: 81, runNumber: 81, headSHA: " AAA ", updatedAt: 200)

    let result = GitHubWorkflowRunSupersessionResolver().resolve(runs: [old, current])

    #expect(result.supersededRunIDs.isEmpty)
    #expect(result.currentRuns.map(\.id) == [81, 80])
}

@Test
func differentWorkflowIDsKeepBothRuns() throws {
    let first = try supersessionRun(
        id: 80,
        workflowID: 41,
        runNumber: 80,
        headSHA: "aaa",
        updatedAt: 100
    )
    let second = try supersessionRun(
        id: 81,
        workflowID: 42,
        runNumber: 81,
        headSHA: "bbb",
        updatedAt: 200
    )

    let result = GitHubWorkflowRunSupersessionResolver().resolve(runs: [first, second])

    #expect(result.supersededRunIDs.isEmpty)
    #expect(result.currentRuns.map(\.id) == [81, 80])
}

@Test
func differentEventsKeepBothRuns() throws {
    let first = try supersessionRun(
        id: 80,
        event: "pull_request",
        runNumber: 80,
        headSHA: "aaa",
        updatedAt: 100
    )
    let second = try supersessionRun(
        id: 81,
        event: "pull_request_target",
        runNumber: 81,
        headSHA: "bbb",
        updatedAt: 200
    )

    let result = GitHubWorkflowRunSupersessionResolver().resolve(runs: [first, second])

    #expect(result.supersededRunIDs.isEmpty)
    #expect(result.currentRuns.map(\.id) == [81, 80])
}

@Test
func differentPullRequestsKeepBothRuns() throws {
    let first = try supersessionRun(
        id: 80,
        runNumber: 80,
        headSHA: "aaa",
        pullRequests: [120],
        updatedAt: 100
    )
    let second = try supersessionRun(
        id: 81,
        runNumber: 81,
        headSHA: "bbb",
        pullRequests: [121],
        updatedAt: 200
    )

    let result = GitHubWorkflowRunSupersessionResolver().resolve(runs: [first, second])

    #expect(result.supersededRunIDs.isEmpty)
    #expect(result.currentRuns.map(\.id) == [81, 80])
}

@Test
func branchOnlyRunsKeepBothRuns() throws {
    let first = try supersessionRun(
        id: 80,
        event: "push",
        runNumber: 80,
        headSHA: "aaa",
        pullRequests: [],
        updatedAt: 100
    )
    let second = try supersessionRun(
        id: 81,
        event: "push",
        runNumber: 81,
        headSHA: "bbb",
        pullRequests: [],
        updatedAt: 200
    )

    let result = GitHubWorkflowRunSupersessionResolver().resolve(runs: [first, second])

    #expect(result.supersededRunIDs.isEmpty)
    #expect(result.currentRuns.map(\.id) == [81, 80])
}

@Test
func multiplePullRequestsKeepRuns() throws {
    let first = try supersessionRun(
        id: 80,
        runNumber: 80,
        headSHA: "aaa",
        pullRequests: [120, 121],
        updatedAt: 100
    )
    let second = try supersessionRun(
        id: 81,
        runNumber: 81,
        headSHA: "bbb",
        pullRequests: [120, 121],
        updatedAt: 200
    )

    let result = GitHubWorkflowRunSupersessionResolver().resolve(runs: [first, second])

    #expect(result.supersededRunIDs.isEmpty)
    #expect(result.currentRuns.map(\.id) == [81, 80])
}

@Test
func duplicateMaximumRunNumberKeepsEntireLane() throws {
    let old = try supersessionRun(id: 80, runNumber: 80, headSHA: "aaa", updatedAt: 100)
    let firstMax = try supersessionRun(id: 81, runNumber: 81, headSHA: "bbb", updatedAt: 190)
    let secondMax = try supersessionRun(id: 82, runNumber: 81, headSHA: "ccc", updatedAt: 200)

    let result = GitHubWorkflowRunSupersessionResolver().resolve(runs: [old, firstMax, secondMax])

    #expect(result.supersededRunIDs.isEmpty)
    #expect(result.currentRuns.map(\.id) == [82, 81, 80])
}

@Test
func emptyNormalizedNewestSHAKeepsLane() throws {
    let old = try supersessionRun(id: 80, runNumber: 80, headSHA: "aaa", updatedAt: 100)
    let current = try supersessionRun(id: 81, runNumber: 81, headSHA: "   ", updatedAt: 200)

    let result = GitHubWorkflowRunSupersessionResolver().resolve(runs: [old, current])

    #expect(result.supersededRunIDs.isEmpty)
    #expect(result.currentRuns.map(\.id) == [81, 80])
}

@Test
func emptyNormalizedOlderSHAIsNotSuppressed() throws {
    let old = try supersessionRun(id: 80, runNumber: 80, headSHA: "   ", updatedAt: 100)
    let current = try supersessionRun(id: 81, runNumber: 81, headSHA: "bbb", updatedAt: 200)

    let result = GitHubWorkflowRunSupersessionResolver().resolve(runs: [old, current])

    #expect(result.supersededRunIDs.isEmpty)
    #expect(result.currentRuns.map(\.id) == [81, 80])
}

@Test
func threeGenerationsKeepCurrentSHAFamily() throws {
    let oldest = try supersessionRun(id: 80, runNumber: 80, headSHA: "aaa", updatedAt: 100)
    let sameCurrentSHA = try supersessionRun(id: 81, runNumber: 81, headSHA: "bbb", updatedAt: 180)
    let current = try supersessionRun(id: 82, runNumber: 82, headSHA: "BBB", updatedAt: 200)

    let result = GitHubWorkflowRunSupersessionResolver().resolve(
        runs: [sameCurrentSHA, oldest, current]
    )

    #expect(result.supersededRunIDs == Set([80]))
    #expect(result.currentRuns.map(\.id) == [82, 81])
}

@Test
func shuffledInputProducesSameResolution() throws {
    let old = try supersessionRun(id: 80, runNumber: 80, headSHA: "aaa", updatedAt: 100)
    let current = try supersessionRun(id: 81, runNumber: 81, headSHA: "bbb", updatedAt: 200)
    let unrelated = try supersessionRun(
        id: 90,
        workflowID: 99,
        runNumber: 3,
        headSHA: "zzz",
        pullRequests: [200],
        updatedAt: 150
    )
    let resolver = GitHubWorkflowRunSupersessionResolver()

    let first = resolver.resolve(runs: [old, current, unrelated])
    let second = resolver.resolve(runs: [unrelated, current, old])

    #expect(first == second)
    #expect(first.currentRuns.map(\.id) == [81, 90])
}

private func supersessionRun(
    id: Int64,
    workflowID: Int64 = 41,
    event: String = "pull_request",
    runNumber: Int,
    headSHA: String,
    pullRequests: [Int] = [120],
    updatedAt: TimeInterval,
    status: GitHubWorkflowRunStatus = .inProgress,
    conclusion: GitHubWorkflowRunConclusion? = nil
) throws -> GitHubWorkflowRun {
    GitHubWorkflowRun(
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
        createdAt: Date(timeIntervalSince1970: updatedAt - 10),
        updatedAt: Date(timeIntervalSince1970: updatedAt)
    )
}

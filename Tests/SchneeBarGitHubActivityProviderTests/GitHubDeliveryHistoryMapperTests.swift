import Foundation
import SchneeBarCore
import SchneeBarGitHub
import SchneeBarGitHubActivityProvider
import Testing

@Test
func deliveryHistoryMapperPreservesCompletedRunsAndSortsDeterministically() throws {
    let repository = try historyRepository(defaultBranch: "main")
    let sameTime = Date(timeIntervalSince1970: 300)
    let runs = [
        historyRun(
            id: 801,
            name: "Release",
            branch: "release/1.x",
            conclusion: .failure,
            runNumber: 81,
            updatedAt: Date(timeIntervalSince1970: 200)
        ),
        historyRun(
            id: 803,
            name: "CI",
            branch: "main",
            conclusion: .success,
            runNumber: 83,
            updatedAt: sameTime
        ),
        historyRun(
            id: 802,
            name: "CI",
            branch: "Main",
            conclusion: .cancelled,
            runNumber: 82,
            updatedAt: sameTime
        ),
    ]

    let snapshot = GitHubDeliveryHistoryMapper().map(
        repository: repository,
        runs: runs
    )

    #expect(snapshot.repository == "snow/repo")
    #expect(snapshot.entries.map(\.id) == [
        "github-actions:42:803",
        "github-actions:42:802",
        "github-actions:42:801",
    ])
    #expect(snapshot.entries[0].title == "CI")
    #expect(snapshot.entries[0].detail == "Succeeded · Default branch · Run #83")
    #expect(snapshot.entries[0].state == .success)
    #expect(snapshot.entries[1].detail == "Cancelled · Main · Run #82")
    #expect(snapshot.entries[1].state == .neutral)
    #expect(snapshot.entries[2].detail == "Failed · release/1.x · Run #81")
    #expect(snapshot.entries[2].state == .failed)
}

@Test
func deliveryHistoryMapperUsesConservativeCompletedStates() throws {
    let repository = try historyRepository(defaultBranch: nil)
    let runs = [
        historyRun(id: 810, branch: nil, conclusion: .timedOut),
        historyRun(id: 809, branch: " ", conclusion: .startupFailure),
        historyRun(id: 808, branch: "topic", conclusion: .actionRequired),
        historyRun(id: 807, branch: "topic", conclusion: .skipped),
        historyRun(id: 806, branch: "topic", conclusion: .neutral),
        historyRun(id: 805, branch: "topic", conclusion: .stale),
        historyRun(id: 804, branch: "topic", conclusion: .unknown("future")),
        historyRun(id: 803, branch: "topic", conclusion: nil),
    ]

    let entries = GitHubDeliveryHistoryMapper()
        .map(repository: repository, runs: runs)
        .entries

    #expect(entries[0].detail == "Timed out · Branch unavailable · Run #810")
    #expect(entries[0].state == .failed)
    #expect(entries[1].detail == "Startup failure · Branch unavailable · Run #809")
    #expect(entries[1].state == .failed)
    #expect(entries[2].detail == "Action required · topic · Run #808")
    #expect(entries[2].state == .failed)
    #expect(entries.dropFirst(3).allSatisfy { $0.state == .neutral })
    #expect(entries[3].detail == "Skipped · topic · Run #807")
    #expect(entries[6].detail == "Completed · topic · Run #804")
    #expect(entries[7].detail == "Completed · topic · Run #803")
}

@Test
func deliveryHistoryMapperDoesNotExposeRawSHA() throws {
    let repository = try historyRepository(defaultBranch: "main")
    let rawSHA = "0123456789abcdef0123456789abcdef01234567"
    let run = historyRun(
        id: 900,
        branch: "main",
        conclusion: .success,
        headSHA: rawSHA
    )

    let entry = try #require(
        GitHubDeliveryHistoryMapper()
            .map(repository: repository, runs: [run])
            .entries.first
    )

    #expect(!entry.title.contains(rawSHA))
    #expect(entry.detail?.contains(rawSHA) == false)
    #expect(entry.destinationURL?.absoluteString.contains(rawSHA) == false)
}

private func historyRepository(
    defaultBranch: String?
) throws -> GitHubRepositoryAccess {
    GitHubRepositoryAccess(
        id: 42,
        name: "repo",
        fullName: "snow/repo",
        isPrivate: true,
        webURL: try #require(URL(string: "https://github.com/snow/repo")),
        ownerLogin: "snow",
        permissions: GitHubRepositoryPermissions(pull: true),
        defaultBranch: defaultBranch
    )
}

private func historyRun(
    id: Int64,
    name: String = "CI",
    branch: String?,
    conclusion: GitHubWorkflowRunConclusion?,
    runNumber: Int? = nil,
    headSHA: String = "head-sha",
    updatedAt: Date? = nil
) -> GitHubWorkflowRun {
    let occurredAt = updatedAt ?? Date(timeIntervalSince1970: TimeInterval(id))
    return GitHubWorkflowRun(
        id: id,
        workflowID: 88,
        name: name,
        displayTitle: name,
        event: "push",
        status: .completed,
        conclusion: conclusion,
        runNumber: runNumber ?? Int(id),
        headBranch: branch,
        headSHA: headSHA,
        webURL: URL(string: "https://github.com/snow/repo/actions/runs/\(id)")!,
        pullRequestNumbers: [],
        createdAt: occurredAt.addingTimeInterval(-30),
        updatedAt: occurredAt
    )
}

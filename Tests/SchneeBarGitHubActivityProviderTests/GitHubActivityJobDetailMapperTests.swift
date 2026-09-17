import Foundation
import SchneeBarCore
import SchneeBarGitHub
import SchneeBarGitHubActivityProvider
import Testing

@Test
func jobDetailMapperPrioritizesFailedAndRunningJobs() throws {
    let item = ActivityItem(
        id: "github-actions:42:501",
        repository: "octocat/project",
        context: "PR #21 · CI",
        detail: "Failed · Build",
        state: .failed,
        destinationURL: try #require(
            URL(string: "https://github.com/octocat/project/actions/runs/501")
        )
    )

    let jobs = [
        try detailJob(
            id: 1,
            name: "Docs",
            status: .completed,
            conclusion: .success,
            startedAt: 0,
            completedAt: 9
        ),
        try detailJob(
            id: 2,
            name: "Tests (macos-15)",
            status: .completed,
            conclusion: .failure,
            steps: [
                detailStep(number: 1, name: "Checkout", conclusion: .success),
                detailStep(number: 2, name: "Test", conclusion: .failure),
            ]
        ),
        try detailJob(
            id: 3,
            name: "Windows",
            status: .inProgress,
            conclusion: nil
        ),
        try detailJob(
            id: 4,
            name: "Integration",
            status: .queued,
            conclusion: nil
        ),
    ]

    let snapshot = GitHubActivityJobDetailMapper().map(item: item, jobs: jobs)

    #expect(snapshot.id == item.id)
    #expect(snapshot.repository == "octocat/project")
    #expect(snapshot.title == "PR #21 · CI")
    #expect(snapshot.state == .failed)
    #expect(snapshot.summary == "2/4 jobs · 1 failed · 1 running · 1 waiting")
    #expect(snapshot.destinationURL == item.destinationURL)
    #expect(snapshot.rows.map(\.title) == [
        "Tests (macos-15)",
        "Windows",
        "Integration",
        "Docs",
    ])
    #expect(snapshot.rows.map(\.state) == [.failed, .running, .waiting, .success])
    #expect(snapshot.rows[0].detail == "Failed at Test")
    #expect(snapshot.rows[3].detail == "Succeeded · 9s")
}

@Test
func jobDetailMapperKeepsCancelledJobsNeutral() throws {
    let item = ActivityItem(
        id: "github-actions:42:502",
        repository: "octocat/project",
        context: "main · CI",
        detail: "Running · Build",
        state: .running
    )
    let cancelled = try detailJob(
        id: 9,
        name: "Cancelled matrix leg",
        status: .completed,
        conclusion: .cancelled
    )

    let snapshot = GitHubActivityJobDetailMapper().map(
        item: item,
        jobs: [cancelled]
    )

    #expect(snapshot.summary == "1/1 jobs · 1 cancelled")
    #expect(snapshot.rows.first?.state == .neutral)
    #expect(snapshot.rows.first?.detail == "Cancelled")
}

@Test
func jobDetailMapperAggregatesVariantsWithoutChangingRawSummary() throws {
    let item = ActivityItem(
        id: "github-actions:42:501",
        repository: "octocat/project",
        context: "PR #21 · CI",
        detail: "Failed · Test",
        state: .failed,
        destinationURL: try #require(
            URL(string: "https://github.com/octocat/project/actions/runs/501")
        )
    )

    let jobs = [
        try detailJob(id: 90, name: "Docs", status: .completed, conclusion: .success),
        try detailJob(
            id: 11,
            name: "Test (macos)",
            status: .completed,
            conclusion: .failure,
            steps: [
                detailStep(number: 1, name: "Checkout", conclusion: .success),
                detailStep(number: 2, name: "Unit tests", conclusion: .failure),
            ]
        ),
        try detailJob(id: 12, name: "Test (linux)", status: .inProgress, conclusion: nil),
        try detailJob(id: 13, name: "Test (windows)", status: .queued, conclusion: nil),
        try detailJob(
            id: 14,
            name: "Test (ios)",
            status: .completed,
            conclusion: .success,
            startedAt: 0,
            completedAt: 12
        ),
        try detailJob(id: 15, name: "Test (freebsd)", status: .completed, conclusion: .cancelled),
    ]

    let snapshot = GitHubActivityJobDetailMapper().map(item: item, jobs: jobs)

    #expect(snapshot.summary == "4/6 jobs · 1 failed · 1 running · 1 waiting · 1 cancelled")
    #expect(snapshot.rows.map(\.title) == ["Test", "Docs"])

    let group = try #require(snapshot.rows.first)
    #expect(group.id == "github-job-group:501:Test")
    #expect(group.title == "Test")
    #expect(group.detail == "5 variants · 1 failed · 1 running · 1 waiting · 1 cancelled")
    #expect(group.state == .failed)
    #expect(group.destinationURL == nil)
    #expect(group.children.map(\.title) == ["macos", "linux", "windows", "ios", "freebsd"])
    #expect(group.children.map(\.state) == [.failed, .running, .waiting, .success, .neutral])
    #expect(group.children[0].detail == "Failed at Unit tests")
    #expect(group.children[0].destinationURL?.absoluteString.hasSuffix("/job/11") == true)
    #expect(group.children[3].detail == "Succeeded · 12s")
    #expect(group.children[3].destinationURL?.absoluteString.hasSuffix("/job/14") == true)
    #expect(group.children[4].detail == "Cancelled")
}

@Test
func jobDetailMapperUsesSuccessForSuccessAndNeutralVariantGroup() throws {
    let item = ActivityItem(
        id: "github-actions:42:501",
        repository: "octocat/project",
        context: "main · CI",
        detail: "Completed",
        state: .success
    )

    let snapshot = GitHubActivityJobDetailMapper().map(
        item: item,
        jobs: [
            try detailJob(id: 21, name: "Test (macos)", status: .completed, conclusion: .success),
            try detailJob(id: 22, name: "Test (linux)", status: .completed, conclusion: .cancelled),
        ]
    )

    #expect(snapshot.summary == "2/2 jobs · 1 cancelled")
    let group = try #require(snapshot.rows.first)
    #expect(group.state == .success)
    #expect(group.detail == "2 variants · 1 cancelled")
    #expect(group.children.map(\.title) == ["macos", "linux"])
    #expect(group.children.map(\.state) == [.success, .neutral])
}

@Test
func jobDetailMapperUsesNeutralForNeutralOnlyVariantGroup() throws {
    let item = ActivityItem(
        id: "github-actions:42:501",
        repository: "octocat/project",
        context: "main · CI",
        detail: "Completed",
        state: .success
    )

    let snapshot = GitHubActivityJobDetailMapper().map(
        item: item,
        jobs: [
            try detailJob(id: 31, name: "Test (macos)", status: .completed, conclusion: .cancelled),
            try detailJob(id: 32, name: "Test (linux)", status: .completed, conclusion: .skipped),
        ]
    )

    let group = try #require(snapshot.rows.first)
    #expect(group.state == .neutral)
    #expect(group.detail == "2 variants · 1 cancelled")
    #expect(group.children.map(\.state) == [.neutral, .neutral])
}

private func detailJob(
    id: Int64,
    name: String,
    status: GitHubWorkflowJobStatus,
    conclusion: GitHubWorkflowJobConclusion?,
    startedAt: TimeInterval? = nil,
    completedAt: TimeInterval? = nil,
    steps: [GitHubWorkflowJobStep] = []
) throws -> GitHubWorkflowJob {
    GitHubWorkflowJob(
        id: id,
        runID: 501,
        name: name,
        status: status,
        conclusion: conclusion,
        startedAt: startedAt.map(Date.init(timeIntervalSince1970:)),
        completedAt: completedAt.map(Date.init(timeIntervalSince1970:)),
        webURL: try #require(
            URL(string: "https://github.com/octocat/project/actions/runs/501/job/\(id)")
        ),
        runnerName: nil,
        runnerGroupName: nil,
        labels: [],
        steps: steps
    )
}

private func detailStep(
    number: Int,
    name: String,
    conclusion: GitHubWorkflowJobConclusion
) -> GitHubWorkflowJobStep {
    GitHubWorkflowJobStep(
        number: number,
        name: name,
        status: .completed,
        conclusion: conclusion,
        startedAt: nil,
        completedAt: nil
    )
}

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

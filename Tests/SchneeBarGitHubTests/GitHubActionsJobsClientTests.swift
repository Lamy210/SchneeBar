import Foundation
import SchneeBarGitHub
import Testing

private struct JobsStubResponse: Sendable {
    let json: String
    let statusCode: Int

    init(_ json: String, statusCode: Int = 200) {
        self.json = json
        self.statusCode = statusCode
    }
}

private actor JobsQueueTransport: GitHubHTTPTransport {
    private var responses: [JobsStubResponse]
    private var requests: [URLRequest] = []

    init(_ responses: [JobsStubResponse]) {
        self.responses = responses
    }

    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        requests.append(request)
        let response = responses.isEmpty
            ? JobsStubResponse(#"{"message":"Unexpected request"}"#, statusCode: 500)
            : responses.removeFirst()
        let httpResponse = try #require(
            HTTPURLResponse(
                url: request.url!,
                statusCode: response.statusCode,
                httpVersion: "HTTP/1.1",
                headerFields: nil
            )
        )
        return (Data(response.json.utf8), httpResponse)
    }

    func recordedRequests() -> [URLRequest] {
        requests
    }
}

@Test
func loadsWorkflowJobsWithStepsAndTrustedWebURL() async throws {
    let transport = JobsQueueTransport([
        JobsStubResponse(
            #"{"total_count":1,"jobs":[{"id":7001,"run_id":501,"name":"Tests (macos-15, swift-6.3)","status":"completed","conclusion":"failure","started_at":"2026-09-12T12:00:00Z","completed_at":"2026-09-12T12:02:30Z","runner_name":"GitHub Actions 9","runner_group_name":"GitHub Actions","labels":["macos-15","arm64"],"html_url":"https://evil.example/job","steps":[{"name":"Checkout","status":"completed","conclusion":"success","number":1,"started_at":"2026-09-12T12:00:01Z","completed_at":"2026-09-12T12:00:05Z"},{"name":"Test","status":"completed","conclusion":"failure","number":2,"started_at":"2026-09-12T12:00:06Z","completed_at":"2026-09-12T12:02:29Z"}]}]}"#
        )
    ])
    let client = GitHubActionsJobsClient(transport: transport)

    let jobs = try await client.jobs(
        runID: 501,
        repository: try jobsRepository(),
        connection: try jobsGitHubDotComConnection(),
        credential: GitHubCredential(accessToken: "ghu_jobs"),
        query: GitHubWorkflowJobQuery(filter: .latest, limit: 25)
    )

    let job = try #require(jobs.first)
    #expect(job.id == 7001)
    #expect(job.runID == 501)
    #expect(job.name == "Tests (macos-15, swift-6.3)")
    #expect(job.status == .completed)
    #expect(job.conclusion == .failure)
    #expect(job.runnerName == "GitHub Actions 9")
    #expect(job.labels == ["macos-15", "arm64"])
    #expect(job.steps.map(\.name) == ["Checkout", "Test"])
    #expect(job.steps[1].conclusion == .failure)
    #expect(job.duration == 150)
    #expect(job.steps[1].duration == 143)
    #expect(job.webURL.absoluteString == "https://github.com/octocat/project/actions/runs/501/job/7001")

    let request = try #require(await transport.recordedRequests().first)
    #expect(request.url?.path == "/repos/octocat/project/actions/runs/501/jobs")
    #expect(queryValue("filter", in: request) == "latest")
    #expect(queryValue("per_page", in: request) == "25")
    #expect(queryValue("page", in: request) == "1")
    #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer ghu_jobs")
    #expect(request.value(forHTTPHeaderField: "X-GitHub-Api-Version") == "2026-03-10")
}

@Test
func loadsWorkflowJobsFromCustomPortGHESWithNegotiatedVersion() async throws {
    let transport = JobsQueueTransport([
        JobsStubResponse(
            #"{"total_count":1,"jobs":[{"id":9001,"run_id":901,"name":"Release","status":"completed","conclusion":"success","started_at":"2026-09-12T10:00:00Z","completed_at":"2026-09-12T10:02:00Z","labels":[],"steps":[]}]}"#
        )
    ])
    let client = GitHubActionsJobsClient(transport: transport)
    var connection = GitHubConnection(
        displayName: "Internal GitHub",
        deploymentKind: .enterpriseServer,
        webBaseURL: try #require(URL(string: "https://github.internal.example:8443"))
    )
    connection.apiVersion = "2022-11-28"

    let jobs = try await client.jobs(
        runID: 901,
        repository: try jobsRepository(
            owner: "acme",
            name: "service-api",
            webBaseURL: "https://github.internal.example:8443"
        ),
        connection: connection,
        credential: GitHubCredential(accessToken: "ghu_enterprise")
    )

    let job = try #require(jobs.first)
    #expect(job.webURL.absoluteString == "https://github.internal.example:8443/acme/service-api/actions/runs/901/job/9001")

    let request = try #require(await transport.recordedRequests().first)
    #expect(request.url?.host == "github.internal.example")
    #expect(request.url?.port == 8443)
    #expect(request.url?.path == "/api/v3/repos/acme/service-api/actions/runs/901/jobs")
    #expect(request.value(forHTTPHeaderField: "X-GitHub-Api-Version") == "2022-11-28")
}

@Test
func paginatesWorkflowJobsUpToRequestedLimit() async throws {
    let first = #"{"total_count":2,"jobs":[{"id":1,"run_id":501,"name":"Test 1","status":"completed","conclusion":"success","started_at":null,"completed_at":null,"labels":[],"steps":[]}]}"#
    let second = #"{"total_count":2,"jobs":[{"id":2,"run_id":501,"name":"Test 2","status":"completed","conclusion":"failure","started_at":null,"completed_at":null,"labels":[],"steps":[]}]}"#
    let transport = JobsQueueTransport([
        JobsStubResponse(first),
        JobsStubResponse(second),
    ])
    let client = GitHubActionsJobsClient(transport: transport)

    let jobs = try await client.jobs(
        runID: 501,
        repository: try jobsRepository(),
        connection: try jobsGitHubDotComConnection(),
        credential: GitHubCredential(accessToken: "ghu_jobs"),
        query: GitHubWorkflowJobQuery(filter: .all, limit: 2)
    )

    #expect(jobs.map(\.id) == [1, 2])
    let requests = await transport.recordedRequests()
    #expect(requests.count == 2)
    #expect(queryValue("filter", in: requests[0]) == "all")
    #expect(queryValue("per_page", in: requests[0]) == "2")
    #expect(queryValue("per_page", in: requests[1]) == "1")
    #expect(queryValue("page", in: requests[1]) == "2")
}

@Test
func preservesUnknownWorkflowJobStateWithoutFailingWholePayload() async throws {
    let transport = JobsQueueTransport([
        JobsStubResponse(
            #"{"total_count":1,"jobs":[{"id":7,"run_id":501,"name":"Future Job","status":"future_status","conclusion":"future_conclusion","started_at":null,"completed_at":null,"labels":[],"steps":[{"name":"Future Step","status":"future_step_status","conclusion":"future_step_conclusion","number":1,"started_at":null,"completed_at":null}]}]}"#
        )
    ])
    let client = GitHubActionsJobsClient(transport: transport)

    let job = try #require(
        try await client.jobs(
            runID: 501,
            repository: jobsRepository(),
            connection: jobsGitHubDotComConnection(),
            credential: GitHubCredential(accessToken: "ghu_jobs")
        ).first
    )

    #expect(job.status == .unknown("future_status"))
    #expect(job.conclusion == .unknown("future_conclusion"))
    #expect(job.steps.first?.status == .unknown("future_step_status"))
    #expect(job.steps.first?.conclusion == .unknown("future_step_conclusion"))
}

@Test
func emptyJobCredentialStopsBeforeNetworkRequest() async throws {
    let transport = JobsQueueTransport([])
    let client = GitHubActionsJobsClient(transport: transport)

    await #expect(throws: GitHubActionsClientError.invalidCredential) {
        try await client.jobs(
            runID: 501,
            repository: jobsRepository(),
            connection: jobsGitHubDotComConnection(),
            credential: GitHubCredential(accessToken: "   ")
        )
    }

    #expect(await transport.recordedRequests().isEmpty)
}

@Test
func invalidRunIDStopsBeforeNetworkRequest() async throws {
    let transport = JobsQueueTransport([])
    let client = GitHubActionsJobsClient(transport: transport)

    await #expect(throws: GitHubActionsClientError.invalidResponse) {
        try await client.jobs(
            runID: 0,
            repository: jobsRepository(),
            connection: jobsGitHubDotComConnection(),
            credential: GitHubCredential(accessToken: "ghu_jobs")
        )
    }

    #expect(await transport.recordedRequests().isEmpty)
}

@Test
func jobSummaryAggregatesExpandedMatrixJobsAndFailedSteps() throws {
    let jobs = [
        try makeJob(id: 1, name: "Tests (macos-15)", status: .completed, conclusion: .success),
        try makeJob(
            id: 2,
            name: "Tests (macos-14)",
            status: .completed,
            conclusion: .failure,
            steps: [
                makeStep(number: 1, name: "Checkout", conclusion: .success),
                makeStep(number: 2, name: "Test", conclusion: .failure),
            ]
        ),
        try makeJob(
            id: 3,
            name: "Linux (swift-6.3)",
            status: .completed,
            conclusion: .timedOut,
            steps: [makeStep(number: 1, name: "Build", conclusion: .timedOut)]
        ),
        try makeJob(id: 4, name: "Windows", status: .inProgress, conclusion: nil),
        try makeJob(id: 5, name: "Integration", status: .queued, conclusion: nil),
        try makeJob(id: 6, name: "Docs", status: .completed, conclusion: .cancelled),
    ]

    let summary = GitHubWorkflowJobSummary(jobs: jobs)

    #expect(summary.totalCount == 6)
    #expect(summary.completedCount == 4)
    #expect(summary.successCount == 1)
    #expect(summary.failedCount == 2)
    #expect(summary.runningCount == 1)
    #expect(summary.waitingCount == 1)
    #expect(summary.cancelledCount == 1)
    #expect(summary.skippedCount == 0)
    #expect(summary.unknownCount == 0)
    #expect(summary.aggregateState == .failed)
    #expect(summary.progressLabel == "4/6 jobs")
    #expect(summary.failedJobs.map(\.id) == [3, 2])
    #expect(summary.failedSteps.map(\.stepName) == ["Build", "Test"])
}

@Test
func completedJobWithoutConclusionIsUnknown() throws {
    let summary = GitHubWorkflowJobSummary(jobs: [
        try makeJob(id: 1, name: "Future", status: .completed, conclusion: nil),
    ])

    #expect(summary.unknownCount == 1)
    #expect(summary.aggregateState == .unknown)
}

private func jobsGitHubDotComConnection() throws -> GitHubConnection {
    GitHubConnection(
        displayName: "GitHub.com",
        deploymentKind: .githubDotCom,
        webBaseURL: try #require(URL(string: "https://github.com"))
    )
}

private func jobsRepository(
    owner: String = "octocat",
    name: String = "project",
    webBaseURL: String = "https://github.com"
) throws -> GitHubRepositoryAccess {
    GitHubRepositoryAccess(
        id: 42,
        name: name,
        fullName: "\(owner)/\(name)",
        isPrivate: false,
        webURL: try #require(URL(string: "\(webBaseURL)/\(owner)/\(name)")),
        ownerLogin: owner,
        permissions: GitHubRepositoryPermissions(pull: true)
    )
}

private func makeJob(
    id: Int64,
    name: String,
    status: GitHubWorkflowJobStatus,
    conclusion: GitHubWorkflowJobConclusion?,
    steps: [GitHubWorkflowJobStep] = []
) throws -> GitHubWorkflowJob {
    GitHubWorkflowJob(
        id: id,
        runID: 501,
        name: name,
        status: status,
        conclusion: conclusion,
        startedAt: nil,
        completedAt: nil,
        webURL: try #require(URL(string: "https://github.com/octocat/project/actions/runs/501/job/\(id)")),
        runnerName: nil,
        runnerGroupName: nil,
        labels: [],
        steps: steps
    )
}

private func makeStep(
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

private func queryValue(_ name: String, in request: URLRequest) -> String? {
    guard let url = request.url,
          let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
    else {
        return nil
    }
    return components.queryItems?.first(where: { $0.name == name })?.value
}

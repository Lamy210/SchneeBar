import Foundation
import SchneeBarGitHub
import Testing

private actor CheckRunRecordingTransport: GitHubHTTPTransport {
    private let data: Data
    private let statusCode: Int
    private var requests: [URLRequest] = []

    init(json: String, statusCode: Int = 200) {
        data = Data(json.utf8)
        self.statusCode = statusCode
    }

    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        requests.append(request)
        let response = try #require(
            HTTPURLResponse(
                url: request.url!,
                statusCode: statusCode,
                httpVersion: "HTTP/1.1",
                headerFields: nil
            )
        )
        return (data, response)
    }

    func recordedRequests() -> [URLRequest] {
        requests
    }
}

@Test(arguments: [
    ("queued", GitHubCheckRunStatus.queued),
    ("in_progress", GitHubCheckRunStatus.inProgress),
    ("completed", GitHubCheckRunStatus.completed),
    ("waiting", GitHubCheckRunStatus.waiting),
    ("requested", GitHubCheckRunStatus.requested),
    ("pending", GitHubCheckRunStatus.pending),
])
func normalizesKnownCheckStatuses(raw: String, expected: GitHubCheckRunStatus) async throws {
    let run = try await loadSingleCheck(status: raw, conclusion: nil)
    #expect(run.status == expected)
}

@Test(arguments: [
    ("action_required", GitHubCheckRunConclusion.actionRequired),
    ("cancelled", GitHubCheckRunConclusion.cancelled),
    ("failure", GitHubCheckRunConclusion.failure),
    ("neutral", GitHubCheckRunConclusion.neutral),
    ("success", GitHubCheckRunConclusion.success),
    ("skipped", GitHubCheckRunConclusion.skipped),
    ("stale", GitHubCheckRunConclusion.stale),
    ("timed_out", GitHubCheckRunConclusion.timedOut),
])
func normalizesKnownCheckConclusions(raw: String, expected: GitHubCheckRunConclusion) async throws {
    let run = try await loadSingleCheck(status: "completed", conclusion: raw)
    #expect(run.conclusion == expected)
}

@Test
func preservesUnknownCheckValuesAndDoesNotTreatStartupFailureAsKnown() async throws {
    let unknownStatus = try await loadSingleCheck(status: "future_status", conclusion: "startup_failure")
    #expect(unknownStatus.status == .unknown("future_status"))
    #expect(unknownStatus.conclusion == .unknown("startup_failure"))
}

@Test
func loadsOnePageOfChecksAndReconstructsTrustedURL() async throws {
    let sha = String(repeating: "a", count: 40)
    let transport = CheckRunRecordingTransport(
        json: checkRunJSON(
            status: "in_progress",
            conclusion: nil,
            sha: sha,
            detailsURL: "https://evil.example/build/7"
        )
    )
    let client = GitHubCheckRunClient(transport: transport)

    let runs = try await client.checkRuns(
        repository: try checkRunRepository(),
        headSHA: sha,
        connection: try checkRunConnection(),
        credential: GitHubCredential(accessToken: "check-token")
    )

    #expect(runs.count == 1)
    #expect(runs[0].appSlug == "github-actions")
    #expect(runs[0].webURL.absoluteString == "https://github.com/octocat/project/commit/\(sha)/checks")

    let recorded = await transport.recordedRequests()
    #expect(recorded.count == 1)
    let request = try #require(recorded.first)
    #expect(request.url?.path == "/repos/octocat/project/commits/\(sha)/check-runs")
    let components = try #require(URLComponents(url: request.url!, resolvingAgainstBaseURL: false))
    #expect(components.queryItems == [URLQueryItem(name: "per_page", value: "100")])
    #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer check-token")
    #expect(
        request.value(forHTTPHeaderField: "X-GitHub-Api-Version")
            == GitHubRESTAPIVersionPolicy.currentVersion
    )
}

@Test
func rejectsBlankOrMalformedCheckSHAWithoutNetworkRequest() async throws {
    let transport = CheckRunRecordingTransport(json: #"{"check_runs":[]}"#)
    let client = GitHubCheckRunClient(transport: transport)
    let repository = try checkRunRepository()
    let connection = try checkRunConnection()
    let credential = GitHubCredential(accessToken: "check-token")

    await #expect(throws: GitHubCheckRunClientError.invalidHeadSHA) {
        try await client.checkRuns(
            repository: repository,
            headSHA: "   ",
            connection: connection,
            credential: credential
        )
    }
    await #expect(throws: GitHubCheckRunClientError.invalidHeadSHA) {
        try await client.checkRuns(
            repository: repository,
            headSHA: "not-a-sha",
            connection: connection,
            credential: credential
        )
    }
    #expect(await transport.recordedRequests().isEmpty)
}

@Test
func rejectsInvalidCheckTimestampPayload() async throws {
    let sha = String(repeating: "b", count: 40)
    let transport = CheckRunRecordingTransport(
        json: #"{"check_runs":[{"id":7,"name":"Codecov","status":"completed","conclusion":"failure","head_sha":"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb","started_at":"not-a-date","completed_at":null,"app":{"slug":"codecov"}}]}"#
    )
    let client = GitHubCheckRunClient(transport: transport)

    await #expect(throws: GitHubCheckRunClientError.invalidResponse) {
        try await client.checkRuns(
            repository: try checkRunRepository(),
            headSHA: sha,
            connection: try checkRunConnection(),
            credential: GitHubCredential(accessToken: "check-token")
        )
    }
}

@Test(arguments: [401, 403, 404])
func reportsCheckHTTPStatus(statusCode: Int) async throws {
    let sha = String(repeating: "c", count: 40)
    let transport = CheckRunRecordingTransport(json: "{}", statusCode: statusCode)
    let client = GitHubCheckRunClient(transport: transport)

    await #expect(throws: GitHubCheckRunClientError.httpStatus(statusCode)) {
        try await client.checkRuns(
            repository: try checkRunRepository(),
            headSHA: sha,
            connection: try checkRunConnection(),
            credential: GitHubCredential(accessToken: "check-token")
        )
    }
}

private func loadSingleCheck(
    status: String,
    conclusion: String?
) async throws -> GitHubCheckRun {
    let sha = String(repeating: "d", count: 40)
    let transport = CheckRunRecordingTransport(
        json: checkRunJSON(status: status, conclusion: conclusion, sha: sha)
    )
    let runs = try await GitHubCheckRunClient(transport: transport).checkRuns(
        repository: try checkRunRepository(),
        headSHA: sha,
        connection: try checkRunConnection(),
        credential: GitHubCredential(accessToken: "check-token")
    )
    return try #require(runs.first)
}

private func checkRunJSON(
    status: String,
    conclusion: String?,
    sha: String,
    detailsURL: String = "https://ci.example/build/7"
) -> String {
    let conclusionJSON = conclusion.map { "\"\($0)\"" } ?? "null"
    return """
    {"total_count":1,"check_runs":[{"id":7,"name":"Codecov","status":"\(status)","conclusion":\(conclusionJSON),"head_sha":"\(sha)","started_at":"2026-09-16T00:00:00Z","completed_at":null,"details_url":"\(detailsURL)","app":{"slug":"github-actions"}}]}
    """
}

private func checkRunConnection() throws -> GitHubConnection {
    GitHubConnection(
        displayName: "GitHub.com",
        deploymentKind: .githubDotCom,
        webBaseURL: try #require(URL(string: "https://github.com"))
    )
}

private func checkRunRepository() throws -> GitHubRepositoryAccess {
    GitHubRepositoryAccess(
        id: 42,
        name: "project",
        fullName: "octocat/project",
        isPrivate: false,
        webURL: try #require(URL(string: "https://github.com/octocat/project")),
        ownerLogin: "octocat",
        permissions: GitHubRepositoryPermissions(pull: true)
    )
}

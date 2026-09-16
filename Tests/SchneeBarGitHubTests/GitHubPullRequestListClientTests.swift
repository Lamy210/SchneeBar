import Foundation
import SchneeBarGitHub
import Testing

private actor PullRequestListRecordingTransport: GitHubHTTPTransport {
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

@Test
func loadsOnePageOfRecentOpenPullRequestsAndNormalizesReviewerIDs() async throws {
    let transport = PullRequestListRecordingTransport(
        json: #"[{"number":7,"title":"Harden recovery","draft":false,"updated_at":"2026-09-16T00:00:00Z","head":{"sha":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"},"requested_reviewers":[{"id":42,"login":"snow-user"},{"id":99,"login":"reviewer"}],"html_url":"https://evil.example/not-trusted"},{"number":8,"title":"Improve checks","draft":true,"updated_at":"2026-09-15T23:00:00Z","head":{"sha":"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"},"requested_reviewers":[]}]"#
    )
    let client = GitHubPullRequestListClient(transport: transport)

    let requests = try await client.openPullRequests(
        repository: try pullRequestListRepository(),
        connection: try pullRequestListConnection(),
        credential: GitHubCredential(accessToken: "test-token")
    )

    #expect(requests.count == 2)
    #expect(requests[0].requestedReviewerIDs == Set(["42", "99"]))
    #expect(requests[0].headSHA == "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa")
    #expect(requests[0].webURL.absoluteString == "https://github.com/octocat/project/pull/7")
    #expect(requests[1].isDraft)

    let recorded = await transport.recordedRequests()
    #expect(recorded.count == 1)
    let request = try #require(recorded.first)
    #expect(request.url?.path == "/repos/octocat/project/pulls")
    let components = try #require(URLComponents(url: request.url!, resolvingAgainstBaseURL: false))
    let query = Dictionary(
        uniqueKeysWithValues: (components.queryItems ?? []).map { ($0.name, $0.value ?? "") }
    )
    #expect(query["state"] == "open")
    #expect(query["sort"] == "updated")
    #expect(query["direction"] == "desc")
    #expect(query["per_page"] == "100")
    #expect(request.value(forHTTPHeaderField: "Accept") == "application/vnd.github+json")
    #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer test-token")
    #expect(
        request.value(forHTTPHeaderField: "X-GitHub-Api-Version")
            == GitHubRESTAPIVersionPolicy.currentVersion
    )
}

@Test
func reconstructsPullRequestURLFromTrustedEnterpriseEndpoint() async throws {
    let transport = PullRequestListRecordingTransport(
        json: #"[{"number":25,"title":"Internal change","draft":false,"updated_at":"2026-09-16T00:00:00Z","head":{"sha":"cccccccccccccccccccccccccccccccccccccccc"},"requested_reviewers":[{"id":42}],"html_url":"https://attacker.example/pull/25"}]"#
    )
    let client = GitHubPullRequestListClient(transport: transport)
    let connection = GitHubConnection(
        displayName: "Enterprise",
        deploymentKind: .enterpriseServer,
        webBaseURL: try #require(URL(string: "https://github.internal.example:8443"))
    )

    let requests = try await client.openPullRequests(
        repository: try pullRequestListRepository(
            webURL: "https://github.internal.example:8443/octocat/project"
        ),
        connection: connection,
        credential: GitHubCredential(accessToken: "test-token")
    )

    #expect(requests[0].webURL.absoluteString == "https://github.internal.example:8443/octocat/project/pull/25")
    #expect(await transport.recordedRequests().first?.url?.path == "/api/v3/repos/octocat/project/pulls")
}

@Test
func rejectsBlankPullRequestCredentialBeforeNetworkRequest() async throws {
    let transport = PullRequestListRecordingTransport(json: "[]")
    let client = GitHubPullRequestListClient(transport: transport)

    await #expect(throws: GitHubPullRequestListClientError.invalidCredential) {
        try await client.openPullRequests(
            repository: try pullRequestListRepository(),
            connection: try pullRequestListConnection(),
            credential: GitHubCredential(accessToken: "   ")
        )
    }
    #expect(await transport.recordedRequests().isEmpty)
}

@Test
func rejectsMalformedPullRequestListPayload() async throws {
    let transport = PullRequestListRecordingTransport(
        json: #"[{"number":7,"title":"Missing head","draft":false,"updated_at":"2026-09-16T00:00:00Z","requested_reviewers":[]}]"#
    )
    let client = GitHubPullRequestListClient(transport: transport)

    await #expect(throws: GitHubPullRequestListClientError.invalidResponse) {
        try await client.openPullRequests(
            repository: try pullRequestListRepository(),
            connection: try pullRequestListConnection(),
            credential: GitHubCredential(accessToken: "test-token")
        )
    }
}

@Test(arguments: [401, 403, 404])
func reportsPullRequestHTTPStatus(statusCode: Int) async throws {
    let transport = PullRequestListRecordingTransport(json: "{}", statusCode: statusCode)
    let client = GitHubPullRequestListClient(transport: transport)

    await #expect(throws: GitHubPullRequestListClientError.httpStatus(statusCode)) {
        try await client.openPullRequests(
            repository: try pullRequestListRepository(),
            connection: try pullRequestListConnection(),
            credential: GitHubCredential(accessToken: "test-token")
        )
    }
}

private func pullRequestListConnection() throws -> GitHubConnection {
    GitHubConnection(
        displayName: "GitHub.com",
        deploymentKind: .githubDotCom,
        webBaseURL: try #require(URL(string: "https://github.com"))
    )
}

private func pullRequestListRepository(
    webURL: String = "https://github.com/octocat/project"
) throws -> GitHubRepositoryAccess {
    GitHubRepositoryAccess(
        id: 42,
        name: "project",
        fullName: "octocat/project",
        isPrivate: false,
        webURL: try #require(URL(string: webURL)),
        ownerLogin: "octocat",
        permissions: GitHubRepositoryPermissions(pull: true)
    )
}

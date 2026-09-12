import Foundation
import SchneeBarGitHub
import Testing

private struct PullRequestStubResponse: Sendable {
    let json: String
    let statusCode: Int

    init(_ json: String, statusCode: Int = 200) {
        self.json = json
        self.statusCode = statusCode
    }
}

private actor PullRequestQueueTransport: GitHubHTTPTransport {
    private var responses: [PullRequestStubResponse]
    private var requests: [URLRequest] = []

    init(_ responses: [PullRequestStubResponse]) {
        self.responses = responses
    }

    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        requests.append(request)
        let response = responses.isEmpty
            ? PullRequestStubResponse(#"{"message":"Unexpected request"}"#, statusCode: 500)
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
func loadsMergedPullRequestWithTrustedWebURL() async throws {
    let transport = PullRequestQueueTransport([
        PullRequestStubResponse(
            #"{"number":25,"state":"closed","draft":false,"merged":true,"merge_commit_sha":"merge123","head":{"ref":"feature/jobs","sha":"head123"},"base":{"ref":"main","sha":"base123"},"updated_at":"2026-09-12T12:02:00Z","merged_at":"2026-09-12T12:01:00Z","html_url":"https://evil.example/pr/25"}"#
        )
    ])
    let client = GitHubPullRequestMetadataClient(transport: transport)

    let metadata = try await client.pullRequest(
        number: 25,
        repository: try pullRequestRepository(),
        connection: try pullRequestGitHubDotComConnection(),
        credential: GitHubCredential(accessToken: "ghu_pull")
    )

    #expect(metadata.number == 25)
    #expect(metadata.state == .closed)
    #expect(metadata.isMerged)
    #expect(!metadata.isDraft)
    #expect(metadata.headRef == "feature/jobs")
    #expect(metadata.headSHA == "head123")
    #expect(metadata.baseRef == "main")
    #expect(metadata.baseSHA == "base123")
    #expect(metadata.mergeCommitSHA == "merge123")
    #expect(metadata.mergedAt != nil)
    #expect(metadata.webURL.absoluteString == "https://github.com/octocat/project/pull/25")

    let request = try #require(await transport.recordedRequests().first)
    #expect(request.url?.path == "/repos/octocat/project/pulls/25")
    #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer ghu_pull")
    #expect(request.value(forHTTPHeaderField: "Accept") == "application/vnd.github+json")
    #expect(
        request.value(forHTTPHeaderField: "X-GitHub-Api-Version")
            == GitHubRESTAPIVersionPolicy.currentVersion
    )
}

@Test
func loadsPullRequestFromCustomPortGHESWithExplicitVersion() async throws {
    let transport = PullRequestQueueTransport([
        PullRequestStubResponse(
            #"{"number":7,"state":"open","draft":true,"merged":false,"merge_commit_sha":null,"head":{"ref":"feature/auth","sha":"head777"},"base":{"ref":"main","sha":"base777"},"updated_at":"2026-09-12T11:00:00.123Z","merged_at":null}"#
        )
    ])
    let client = GitHubPullRequestMetadataClient(transport: transport)
    var connection = GitHubConnection(
        displayName: "Internal GitHub",
        deploymentKind: .enterpriseServer,
        webBaseURL: try #require(URL(string: "https://github.internal.example:8443"))
    )
    connection.apiVersion = "2022-11-28"

    let metadata = try await client.pullRequest(
        number: 7,
        repository: try pullRequestRepository(
            owner: "acme",
            name: "service-api",
            webBaseURL: "https://github.internal.example:8443"
        ),
        connection: connection,
        credential: GitHubCredential(accessToken: "ghu_enterprise")
    )

    #expect(metadata.state == .open)
    #expect(metadata.isDraft)
    #expect(!metadata.isMerged)
    #expect(metadata.mergeCommitSHA == nil)
    #expect(metadata.webURL.absoluteString == "https://github.internal.example:8443/acme/service-api/pull/7")

    let request = try #require(await transport.recordedRequests().first)
    #expect(request.url?.host == "github.internal.example")
    #expect(request.url?.port == 8443)
    #expect(request.url?.path == "/api/v3/repos/acme/service-api/pulls/7")
    #expect(request.value(forHTTPHeaderField: "X-GitHub-Api-Version") == "2022-11-28")
}

@Test
func pullRequestClientRejectsInvalidInputBeforeNetwork() async throws {
    let transport = PullRequestQueueTransport([])
    let client = GitHubPullRequestMetadataClient(transport: transport)

    await #expect(throws: GitHubPullRequestMetadataClientError.invalidPullRequestNumber) {
        _ = try await client.pullRequest(
            number: 0,
            repository: try pullRequestRepository(),
            connection: try pullRequestGitHubDotComConnection(),
            credential: GitHubCredential(accessToken: "ghu_pull")
        )
    }

    await #expect(throws: GitHubPullRequestMetadataClientError.invalidCredential) {
        _ = try await client.pullRequest(
            number: 1,
            repository: try pullRequestRepository(),
            connection: try pullRequestGitHubDotComConnection(),
            credential: GitHubCredential(accessToken: "   ")
        )
    }

    #expect(await transport.recordedRequests().isEmpty)
}

@Test
func pullRequestClientRejectsMismatchedPayloadNumber() async throws {
    let transport = PullRequestQueueTransport([
        PullRequestStubResponse(
            #"{"number":26,"state":"closed","draft":false,"merged":true,"merge_commit_sha":"merge123","head":{"ref":"feature/jobs","sha":"head123"},"base":{"ref":"main","sha":"base123"},"updated_at":"2026-09-12T12:02:00Z","merged_at":"2026-09-12T12:01:00Z"}"#
        )
    ])
    let client = GitHubPullRequestMetadataClient(transport: transport)

    await #expect(throws: GitHubPullRequestMetadataClientError.invalidResponse) {
        _ = try await client.pullRequest(
            number: 25,
            repository: try pullRequestRepository(),
            connection: try pullRequestGitHubDotComConnection(),
            credential: GitHubCredential(accessToken: "ghu_pull")
        )
    }
}

@Test
func pullRequestClientSurfacesHTTPStatus() async throws {
    let transport = PullRequestQueueTransport([
        PullRequestStubResponse(#"{"message":"Forbidden"}"#, statusCode: 403)
    ])
    let client = GitHubPullRequestMetadataClient(transport: transport)

    await #expect(throws: GitHubPullRequestMetadataClientError.httpStatus(403)) {
        _ = try await client.pullRequest(
            number: 25,
            repository: try pullRequestRepository(),
            connection: try pullRequestGitHubDotComConnection(),
            credential: GitHubCredential(accessToken: "ghu_pull")
        )
    }
}

private func pullRequestGitHubDotComConnection() throws -> GitHubConnection {
    GitHubConnection(
        displayName: "GitHub.com",
        deploymentKind: .githubDotCom,
        webBaseURL: try #require(URL(string: "https://github.com"))
    )
}

private func pullRequestRepository(
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

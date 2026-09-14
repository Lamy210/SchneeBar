import Foundation
import SchneeBarGitHub
import Testing

private struct CommitPullRequestStubResponse: Sendable {
    let json: String
    let statusCode: Int

    init(_ json: String, statusCode: Int = 200) {
        self.json = json
        self.statusCode = statusCode
    }
}

private actor CommitPullRequestQueueTransport: GitHubHTTPTransport {
    private var responses: [CommitPullRequestStubResponse]
    private var requests: [URLRequest] = []

    init(_ responses: [CommitPullRequestStubResponse]) {
        self.responses = responses
    }

    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        requests.append(request)
        let response = responses.isEmpty
            ? CommitPullRequestStubResponse(#"{"message":"Unexpected request"}"#, statusCode: 500)
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
func loadsAssociatedPullRequestsForHostedCommit() async throws {
    let transport = CommitPullRequestQueueTransport([
        CommitPullRequestStubResponse(
            #"[{"number":25},{"number":25},{"number":30}]"#
        )
    ])
    let client = GitHubCommitPullRequestClient(transport: transport)

    let numbers = try await client.pullRequestNumbers(
        for: " landed123 ",
        repository: try commitPullRequestRepository(),
        connection: try commitPullRequestGitHubDotComConnection(),
        credential: GitHubCredential(accessToken: "ghu_commit")
    )

    #expect(numbers == [25, 30])

    let request = try #require(await transport.recordedRequests().first)
    #expect(request.url?.path == "/repos/octocat/project/commits/landed123/pulls")
    #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer ghu_commit")
    #expect(request.value(forHTTPHeaderField: "Accept") == "application/vnd.github+json")
    #expect(
        request.value(forHTTPHeaderField: "X-GitHub-Api-Version")
            == GitHubRESTAPIVersionPolicy.currentVersion
    )
}

@Test
func paginatesAssociatedPullRequestsUntilShortPage() async throws {
    let firstPage = (1 ... 100)
        .map { #"{"number":\#($0)}"# }
        .joined(separator: ",")
    let transport = CommitPullRequestQueueTransport([
        CommitPullRequestStubResponse("[\(firstPage)]"),
        CommitPullRequestStubResponse(#"[{"number":101}]"#),
    ])
    let client = GitHubCommitPullRequestClient(transport: transport)

    let numbers = try await client.pullRequestNumbers(
        for: "landed-pagination",
        repository: try commitPullRequestRepository(),
        connection: try commitPullRequestGitHubDotComConnection(),
        credential: GitHubCredential(accessToken: "ghu_commit")
    )

    #expect(numbers == Array(1 ... 101))

    let requests = await transport.recordedRequests()
    #expect(requests.count == 2)
    guard requests.count == 2 else { return }

    let firstQuery = queryValues(for: requests[0])
    #expect(firstQuery["per_page"] == "100")
    #expect(firstQuery["page"] == "1")

    let secondQuery = queryValues(for: requests[1])
    #expect(secondQuery["per_page"] == "100")
    #expect(secondQuery["page"] == "2")
}

private func queryValues(for request: URLRequest) -> [String: String] {
    guard let url = request.url,
          let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
    else {
        return [:]
    }

    return Dictionary(
        uniqueKeysWithValues: (components.queryItems ?? []).compactMap { item in
            item.value.map { (item.name, $0) }
        }
    )
}

private func commitPullRequestGitHubDotComConnection() throws -> GitHubConnection {
    GitHubConnection(
        displayName: "GitHub.com",
        deploymentKind: .githubDotCom,
        webBaseURL: try #require(URL(string: "https://github.com"))
    )
}

private func commitPullRequestRepository(
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

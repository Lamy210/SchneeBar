import Foundation
import SchneeBarGitHub
import Testing

private struct WorkflowMutationStubResponse: Sendable {
    let statusCode: Int
    let headers: [String: String]

    init(
        _ statusCode: Int,
        headers: [String: String] = [:]
    ) {
        self.statusCode = statusCode
        self.headers = headers
    }
}

private actor WorkflowMutationRecordingTransport: GitHubHTTPTransport {
    private var responses: [WorkflowMutationStubResponse]
    private var requests: [URLRequest] = []

    init(statusCodes: [Int]) {
        responses = statusCodes.map(WorkflowMutationStubResponse.init)
    }

    init(responses: [WorkflowMutationStubResponse]) {
        self.responses = responses
    }

    func data(
        for request: URLRequest
    ) async throws -> (Data, HTTPURLResponse) {
        requests.append(request)
        let stub = responses.isEmpty
            ? WorkflowMutationStubResponse(500)
            : responses.removeFirst()
        let response = try #require(
            HTTPURLResponse(
                url: request.url!,
                statusCode: stub.statusCode,
                httpVersion: "HTTP/1.1",
                headerFields: stub.headers
            )
        )
        return (Data(), response)
    }

    func recordedRequests() -> [URLRequest] {
        requests
    }
}

@Test
func rerunsHostedWorkflowWithExactMutationRequest() async throws {
    let transport = WorkflowMutationRecordingTransport(
        statusCodes: [201]
    )
    let client = GitHubWorkflowRunMutationClient(transport: transport)

    try await client.rerun(
        runID: 42,
        repository: try mutationRepository(),
        connection: try mutationGitHubDotComConnection(),
        credential: GitHubCredential(accessToken: " ghu_write ")
    )

    let request = try #require(await transport.recordedRequests().last)
    #expect(request.httpMethod == "POST")
    #expect(
        request.url?.absoluteString
            == "https://api.github.com/repos/octocat/project/actions/runs/42/rerun"
    )
    #expect(
        request.value(forHTTPHeaderField: "Accept")
            == "application/vnd.github+json"
    )
    #expect(
        request.value(forHTTPHeaderField: "Authorization")
            == "Bearer ghu_write"
    )
    #expect(
        request.value(forHTTPHeaderField: "X-GitHub-Api-Version")
            == GitHubRESTAPIVersionPolicy.currentVersion
    )
}

@Test
func cancelsGHESWorkflowUsingTrustedCustomPortEndpoint() async throws {
    let transport = WorkflowMutationRecordingTransport(
        statusCodes: [202]
    )
    let client = GitHubWorkflowRunMutationClient(transport: transport)
    let connection = GitHubConnection(
        displayName: "Internal GitHub",
        deploymentKind: .enterpriseServer,
        webBaseURL: try #require(
            URL(string: "https://github.internal.example:8443")
        ),
        serverVersion: "3.22.0"
    )

    try await client.cancel(
        runID: 99,
        repository: try mutationRepository(),
        connection: connection,
        credential: GitHubCredential(accessToken: "ghu_enterprise")
    )

    let request = try #require(await transport.recordedRequests().last)
    #expect(
        request.url?.absoluteString
            == "https://github.internal.example:8443/api/v3/repos/octocat/project/actions/runs/99/cancel"
    )
    #expect(
        request.value(forHTTPHeaderField: "X-GitHub-Api-Version")
            == GitHubRESTAPIVersionPolicy.currentVersion
    )
}

@Test
func cancelPreservesConflictStatusForCaller() async throws {
    let transport = WorkflowMutationRecordingTransport(
        statusCodes: [409]
    )
    let client = GitHubWorkflowRunMutationClient(transport: transport)

    await #expect(
        throws: GitHubWorkflowRunMutationError.httpStatus(409)
    ) {
        try await client.cancel(
            runID: 7,
            repository: try mutationRepository(),
            connection: try mutationGitHubDotComConnection(),
            credential: GitHubCredential(accessToken: "ghu_write")
        )
    }
}

@Test
func mutationPreservesSanitizedSSORequiredFailureEvidence() async throws {
    let transport = WorkflowMutationRecordingTransport(
        responses: [
            WorkflowMutationStubResponse(
                403,
                headers: [
                    "X-GitHub-SSO":
                        "required; url=https://github.com/orgs/acme/sso?authorization_request=sensitive"
                ]
            )
        ]
    )
    let client = GitHubWorkflowRunMutationClient(transport: transport)

    await #expect(
        throws: GitHubWorkflowRunMutationError.httpFailure(
            GitHubHTTPFailureEvidence(
                statusCode: 403,
                ssoSignal: .required
            )
        )
    ) {
        try await client.rerun(
            runID: 7,
            repository: try mutationRepository(),
            connection: try mutationGitHubDotComConnection(),
            credential: GitHubCredential(accessToken: "ghu_write")
        )
    }
}

@Test
func rerunRequiresExactCreatedStatus() async throws {
    let transport = WorkflowMutationRecordingTransport(
        statusCodes: [202]
    )
    let client = GitHubWorkflowRunMutationClient(transport: transport)

    await #expect(
        throws: GitHubWorkflowRunMutationError.httpStatus(202)
    ) {
        try await client.rerun(
            runID: 7,
            repository: try mutationRepository(),
            connection: try mutationGitHubDotComConnection(),
            credential: GitHubCredential(accessToken: "ghu_write")
        )
    }
}

@Test
func invalidRepositoryStopsBeforeNetworkRequest() async throws {
    let transport = WorkflowMutationRecordingTransport(statusCodes: [])
    let client = GitHubWorkflowRunMutationClient(transport: transport)
    let repository = GitHubRepositoryAccess(
        id: 1,
        name: "   ",
        fullName: "octocat/project",
        isPrivate: true,
        webURL: try #require(
            URL(string: "https://github.com/octocat/project")
        ),
        ownerLogin: "octocat",
        permissions: GitHubRepositoryPermissions(
            push: true,
            pull: true
        )
    )

    await #expect(
        throws: GitHubWorkflowRunMutationError.invalidRepository
    ) {
        try await client.cancel(
            runID: 1,
            repository: repository,
            connection: try mutationGitHubDotComConnection(),
            credential: GitHubCredential(accessToken: "ghu_write")
        )
    }

    #expect(await transport.recordedRequests().isEmpty)
}

@Test
func invalidMutationInputsStopBeforeNetworkRequest() async throws {
    let transport = WorkflowMutationRecordingTransport(statusCodes: [])
    let client = GitHubWorkflowRunMutationClient(transport: transport)
    let repository = try mutationRepository()
    let connection = try mutationGitHubDotComConnection()

    await #expect(
        throws: GitHubWorkflowRunMutationError.invalidRunID
    ) {
        try await client.rerun(
            runID: 0,
            repository: repository,
            connection: connection,
            credential: GitHubCredential(accessToken: "ghu_write")
        )
    }

    await #expect(
        throws: GitHubWorkflowRunMutationError.invalidCredential
    ) {
        try await client.cancel(
            runID: 1,
            repository: repository,
            connection: connection,
            credential: GitHubCredential(accessToken: "   ")
        )
    }

    #expect(await transport.recordedRequests().isEmpty)
}

private func mutationGitHubDotComConnection() throws -> GitHubConnection {
    GitHubConnection(
        displayName: "GitHub.com",
        deploymentKind: .githubDotCom,
        webBaseURL: try #require(URL(string: "https://github.com"))
    )
}

private func mutationRepository() throws -> GitHubRepositoryAccess {
    GitHubRepositoryAccess(
        id: 1,
        name: "project",
        fullName: "octocat/project",
        isPrivate: true,
        webURL: try #require(
            URL(string: "https://github.com/octocat/project")
        ),
        ownerLogin: "octocat",
        permissions: GitHubRepositoryPermissions(
            push: true,
            pull: true
        )
    )
}

import Foundation

public enum GitHubCommitPullRequestClientError: Error, Equatable, Sendable {
    case invalidCredential
    case invalidRepository
    case invalidCommitSHA
    case invalidResponse
    case httpStatus(Int)
}

/// Loads pull requests associated with a commit using GitHub's REST API.
///
/// The client deliberately returns only normalized pull-request numbers. GitHub
/// response URLs and other provider payload details are not exposed beyond this
/// adapter boundary.
public struct GitHubCommitPullRequestClient: Sendable {
    private let transport: any GitHubHTTPTransport

    public init(transport: any GitHubHTTPTransport = URLSessionGitHubHTTPTransport()) {
        self.transport = transport
    }

    public func pullRequestNumbers(
        for commitSHA: String,
        repository: GitHubRepositoryAccess,
        connection: GitHubConnection,
        credential: GitHubCredential
    ) async throws -> [Int] {
        let normalizedCommitSHA = commitSHA.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedCommitSHA.isEmpty else {
            throw GitHubCommitPullRequestClientError.invalidCommitSHA
        }
        guard !repository.ownerLogin.isEmpty, !repository.name.isEmpty else {
            throw GitHubCommitPullRequestClientError.invalidRepository
        }

        let token = credential.accessToken.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty else {
            throw GitHubCommitPullRequestClientError.invalidCredential
        }

        let endpoints = try GitHubEndpointResolver.resolve(
            deploymentKind: connection.deploymentKind,
            webBaseURL: connection.webBaseURL
        )
        let url = endpoints.restBaseURL
            .appendingPathComponent("repos", isDirectory: true)
            .appendingPathComponent(repository.ownerLogin, isDirectory: true)
            .appendingPathComponent(repository.name, isDirectory: true)
            .appendingPathComponent("commits", isDirectory: true)
            .appendingPathComponent(normalizedCommitSHA, isDirectory: true)
            .appendingPathComponent("pulls", isDirectory: false)

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        if let apiVersion = apiVersion(for: connection) {
            request.setValue(apiVersion, forHTTPHeaderField: "X-GitHub-Api-Version")
        }

        let (data, response) = try await transport.data(for: request)
        guard (200 ... 299).contains(response.statusCode) else {
            throw GitHubCommitPullRequestClientError.httpStatus(response.statusCode)
        }

        let payload: [AssociatedPullRequestPayload]
        do {
            payload = try JSONDecoder().decode([AssociatedPullRequestPayload].self, from: data)
        } catch {
            throw GitHubCommitPullRequestClientError.invalidResponse
        }

        guard payload.allSatisfy({ $0.number > 0 }) else {
            throw GitHubCommitPullRequestClientError.invalidResponse
        }

        return Array(Set(payload.map(\.number))).sorted()
    }

    private func apiVersion(for connection: GitHubConnection) -> String? {
        if let explicit = nonEmpty(connection.apiVersion) {
            return explicit
        }

        switch connection.deploymentKind {
        case .githubDotCom, .gheDotCom:
            return GitHubRESTAPIVersionPolicy.currentVersion
        case .enterpriseServer:
            return nil
        }
    }

    private func nonEmpty(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

private struct AssociatedPullRequestPayload: Decodable {
    let number: Int
}

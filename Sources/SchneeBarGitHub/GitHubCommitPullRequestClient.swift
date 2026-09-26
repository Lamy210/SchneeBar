import Foundation

public enum GitHubCommitPullRequestClientError: Error, Equatable, Sendable {
    case invalidCredential
    case invalidRepository
    case invalidCommitSHA
    case invalidResponse
    case httpStatus(Int)
    case paginationLimitExceeded
}

/// Loads pull requests associated with a commit using GitHub's REST API.
///
/// The client deliberately returns only normalized pull-request numbers. GitHub
/// response URLs and other provider payload details are not exposed beyond this
/// adapter boundary.
public struct GitHubCommitPullRequestClient: Sendable {
    private static let pageSize = 100
    private static let maximumPages = 10

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
        let context = try requestContext(
            commitSHA: commitSHA,
            repository: repository,
            connection: connection,
            credential: credential
        )

        var page = 1
        var seenNumbers = Set<Int>()

        while page <= Self.maximumPages {
            let payload = try await associatedPullRequests(
                baseURL: context.baseURL,
                page: page,
                connection: connection,
                token: context.token
            )

            let previousCount = seenNumbers.count
            seenNumbers.formUnion(payload.map(\.number))

            if payload.count < Self.pageSize || seenNumbers.count == previousCount {
                return seenNumbers.sorted()
            }

            page += 1
        }

        throw GitHubCommitPullRequestClientError.paginationLimitExceeded
    }

    /// Loads only the first REST page of commit -> pull-request associations.
    ///
    /// Demand-driven Delivery Timeline correlation uses this bounded variant so
    /// one logical association lookup is exactly one HTTP request. Truncation is
    /// conservative: missing evidence yields no correlation rather than spending
    /// unbounded pagination budget.
    public func firstPagePullRequestNumbers(
        for commitSHA: String,
        repository: GitHubRepositoryAccess,
        connection: GitHubConnection,
        credential: GitHubCredential
    ) async throws -> [Int] {
        let context = try requestContext(
            commitSHA: commitSHA,
            repository: repository,
            connection: connection,
            credential: credential
        )
        let payload = try await associatedPullRequests(
            baseURL: context.baseURL,
            page: 1,
            connection: connection,
            token: context.token
        )
        return Array(Set(payload.map(\.number))).sorted()
    }

    private func requestContext(
        commitSHA: String,
        repository: GitHubRepositoryAccess,
        connection: GitHubConnection,
        credential: GitHubCredential
    ) throws -> (baseURL: URL, token: String) {
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
        let baseURL = endpoints.restBaseURL
            .appendingPathComponent("repos", isDirectory: true)
            .appendingPathComponent(repository.ownerLogin, isDirectory: true)
            .appendingPathComponent(repository.name, isDirectory: true)
            .appendingPathComponent("commits", isDirectory: true)
            .appendingPathComponent(normalizedCommitSHA, isDirectory: true)
            .appendingPathComponent("pulls", isDirectory: false)

        return (baseURL, token)
    }

    private func associatedPullRequests(
        baseURL: URL,
        page: Int,
        connection: GitHubConnection,
        token: String
    ) async throws -> [AssociatedPullRequestPayload] {
        let url = try requestURL(baseURL: baseURL, page: page)
        let payload: [AssociatedPullRequestPayload] = try await get(
            url: url,
            connection: connection,
            token: token
        )

        guard payload.allSatisfy({ $0.number > 0 }) else {
            throw GitHubCommitPullRequestClientError.invalidResponse
        }
        return payload
    }

    private func get<Response: Decodable>(
        url: URL,
        connection: GitHubConnection,
        token: String
    ) async throws -> Response {
        var request = URLRequest(url: url)
        GitHubRequestHeaderPolicy.apply(to: &request)
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

        do {
            return try JSONDecoder().decode(Response.self, from: data)
        } catch {
            throw GitHubCommitPullRequestClientError.invalidResponse
        }
    }

    private func requestURL(baseURL: URL, page: Int) throws -> URL {
        guard var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false) else {
            throw GitHubCommitPullRequestClientError.invalidResponse
        }
        components.queryItems = [
            URLQueryItem(name: "per_page", value: String(Self.pageSize)),
            URLQueryItem(name: "page", value: String(page)),
        ]
        guard let url = components.url else {
            throw GitHubCommitPullRequestClientError.invalidResponse
        }
        return url
    }

    private func apiVersion(
        for connection: GitHubConnection
    ) -> String? {
        GitHubRESTAPIVersionPolicy().headerVersion(for: connection)
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

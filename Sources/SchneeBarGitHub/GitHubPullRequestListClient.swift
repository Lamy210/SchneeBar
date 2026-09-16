import Foundation

public struct GitHubReviewRequest: Equatable, Sendable {
    public let number: Int
    public let title: String
    public let headSHA: String
    public let isDraft: Bool
    public let updatedAt: Date
    public let requestedReviewerIDs: Set<String>
    public let webURL: URL

    public init(
        number: Int,
        title: String,
        headSHA: String,
        isDraft: Bool,
        updatedAt: Date,
        requestedReviewerIDs: Set<String>,
        webURL: URL
    ) {
        self.number = number
        self.title = title
        self.headSHA = headSHA
        self.isDraft = isDraft
        self.updatedAt = updatedAt
        self.requestedReviewerIDs = requestedReviewerIDs
        self.webURL = webURL
    }
}

public enum GitHubPullRequestListClientError: Error, Equatable, Sendable {
    case invalidCredential
    case invalidRepository
    case invalidResponse
    case httpStatus(Int)
}

public struct GitHubPullRequestListClient: Sendable {
    private let transport: any GitHubHTTPTransport

    public init(transport: any GitHubHTTPTransport = URLSessionGitHubHTTPTransport()) {
        self.transport = transport
    }

    public func openPullRequests(
        repository: GitHubRepositoryAccess,
        connection: GitHubConnection,
        credential: GitHubCredential
    ) async throws -> [GitHubReviewRequest] {
        let token = credential.accessToken.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty else {
            throw GitHubPullRequestListClientError.invalidCredential
        }
        guard !repository.ownerLogin.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !repository.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            throw GitHubPullRequestListClientError.invalidRepository
        }

        let endpoints = try GitHubEndpointResolver.resolve(
            deploymentKind: connection.deploymentKind,
            webBaseURL: connection.webBaseURL
        )
        let baseURL = endpoints.restBaseURL
            .appendingPathComponent("repos", isDirectory: true)
            .appendingPathComponent(repository.ownerLogin, isDirectory: true)
            .appendingPathComponent(repository.name, isDirectory: true)
            .appendingPathComponent("pulls", isDirectory: false)
        let url = try requestURL(baseURL: baseURL)

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        if let apiVersion = apiVersion(for: connection) {
            request.setValue(apiVersion, forHTTPHeaderField: "X-GitHub-Api-Version")
        }

        let (data, response) = try await transport.data(for: request)
        guard (200 ... 299).contains(response.statusCode) else {
            throw GitHubPullRequestListClientError.httpStatus(response.statusCode)
        }

        let payloads: [PullRequestListPayload]
        do {
            payloads = try JSONDecoder().decode([PullRequestListPayload].self, from: data)
        } catch {
            throw GitHubPullRequestListClientError.invalidResponse
        }

        return try payloads.map {
            try map(
                $0,
                repository: repository,
                webBaseURL: endpoints.webBaseURL
            )
        }
    }

    private func requestURL(baseURL: URL) throws -> URL {
        guard var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false) else {
            throw GitHubPullRequestListClientError.invalidResponse
        }
        components.queryItems = [
            URLQueryItem(name: "state", value: "open"),
            URLQueryItem(name: "sort", value: "updated"),
            URLQueryItem(name: "direction", value: "desc"),
            URLQueryItem(name: "per_page", value: "100"),
        ]
        guard let url = components.url else {
            throw GitHubPullRequestListClientError.invalidResponse
        }
        return url
    }

    private func map(
        _ payload: PullRequestListPayload,
        repository: GitHubRepositoryAccess,
        webBaseURL: URL
    ) throws -> GitHubReviewRequest {
        guard payload.number > 0,
              let title = nonEmpty(payload.title),
              let headSHA = nonEmpty(payload.head.sha),
              let updatedAt = parseGitHubDate(payload.updatedAt)
        else {
            throw GitHubPullRequestListClientError.invalidResponse
        }

        let reviewerIDs = Set(
            (payload.requestedReviewers ?? []).compactMap { reviewer -> String? in
                guard reviewer.id > 0 else { return nil }
                return String(reviewer.id)
            }
        )
        let webURL = webBaseURL
            .appendingPathComponent(repository.ownerLogin, isDirectory: true)
            .appendingPathComponent(repository.name, isDirectory: true)
            .appendingPathComponent("pull", isDirectory: true)
            .appendingPathComponent(String(payload.number), isDirectory: false)

        return GitHubReviewRequest(
            number: payload.number,
            title: title,
            headSHA: headSHA,
            isDraft: payload.draft ?? false,
            updatedAt: updatedAt,
            requestedReviewerIDs: reviewerIDs,
            webURL: webURL
        )
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

    private func parseGitHubDate(_ value: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: value) {
            return date
        }

        let standard = ISO8601DateFormatter()
        standard.formatOptions = [.withInternetDateTime]
        return standard.date(from: value)
    }

    private func nonEmpty(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

private struct PullRequestListPayload: Decodable {
    let number: Int
    let title: String
    let draft: Bool?
    let updatedAt: String
    let head: PullRequestListHeadPayload
    let requestedReviewers: [PullRequestReviewerPayload]?

    private enum CodingKeys: String, CodingKey {
        case number
        case title
        case draft
        case updatedAt = "updated_at"
        case head
        case requestedReviewers = "requested_reviewers"
    }
}

private struct PullRequestListHeadPayload: Decodable {
    let sha: String
}

private struct PullRequestReviewerPayload: Decodable {
    let id: Int64
}

import Foundation

public enum GitHubPullRequestState: Equatable, Sendable {
    case open
    case closed
    case unknown(String)

    init(rawValue: String) {
        switch rawValue {
        case "open": self = .open
        case "closed": self = .closed
        default: self = .unknown(rawValue)
        }
    }
}

public struct GitHubPullRequestMetadata: Equatable, Sendable {
    public let number: Int
    public let state: GitHubPullRequestState
    public let isDraft: Bool
    public let isMerged: Bool
    public let headRef: String
    public let headSHA: String
    public let baseRef: String
    public let baseSHA: String
    public let mergeCommitSHA: String?
    public let webURL: URL
    public let updatedAt: Date
    public let mergedAt: Date?

    public init(
        number: Int,
        state: GitHubPullRequestState,
        isDraft: Bool,
        isMerged: Bool,
        headRef: String,
        headSHA: String,
        baseRef: String,
        baseSHA: String,
        mergeCommitSHA: String?,
        webURL: URL,
        updatedAt: Date,
        mergedAt: Date?
    ) {
        self.number = number
        self.state = state
        self.isDraft = isDraft
        self.isMerged = isMerged
        self.headRef = headRef
        self.headSHA = headSHA
        self.baseRef = baseRef
        self.baseSHA = baseSHA
        self.mergeCommitSHA = mergeCommitSHA
        self.webURL = webURL
        self.updatedAt = updatedAt
        self.mergedAt = mergedAt
    }
}

public enum GitHubPullRequestMetadataClientError: Error, Equatable, Sendable {
    case invalidCredential
    case invalidRepository
    case invalidPullRequestNumber
    case invalidResponse
    case httpStatus(Int)
}

/// Loads the minimal pull-request metadata SchneeBar needs for correlation.
///
/// The payload's `html_url` is intentionally ignored. The browser destination
/// is rebuilt from the trusted connection endpoint and repository identity.
public struct GitHubPullRequestMetadataClient: Sendable {
    private let transport: any GitHubHTTPTransport

    public init(transport: any GitHubHTTPTransport = URLSessionGitHubHTTPTransport()) {
        self.transport = transport
    }

    public func pullRequest(
        number: Int,
        repository: GitHubRepositoryAccess,
        connection: GitHubConnection,
        credential: GitHubCredential
    ) async throws -> GitHubPullRequestMetadata {
        guard number > 0 else {
            throw GitHubPullRequestMetadataClientError.invalidPullRequestNumber
        }
        guard !repository.ownerLogin.isEmpty, !repository.name.isEmpty else {
            throw GitHubPullRequestMetadataClientError.invalidRepository
        }

        let token = credential.accessToken.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty else {
            throw GitHubPullRequestMetadataClientError.invalidCredential
        }

        let endpoints = try GitHubEndpointResolver.resolve(
            deploymentKind: connection.deploymentKind,
            webBaseURL: connection.webBaseURL
        )
        let url = endpoints.restBaseURL
            .appendingPathComponent("repos", isDirectory: true)
            .appendingPathComponent(repository.ownerLogin, isDirectory: true)
            .appendingPathComponent(repository.name, isDirectory: true)
            .appendingPathComponent("pulls", isDirectory: true)
            .appendingPathComponent(String(number), isDirectory: false)

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        if let apiVersion = apiVersion(for: connection) {
            request.setValue(apiVersion, forHTTPHeaderField: "X-GitHub-Api-Version")
        }

        let (data, response) = try await transport.data(for: request)
        guard (200 ... 299).contains(response.statusCode) else {
            throw GitHubPullRequestMetadataClientError.httpStatus(response.statusCode)
        }

        let payload: PullRequestPayload
        do {
            payload = try JSONDecoder().decode(PullRequestPayload.self, from: data)
        } catch {
            throw GitHubPullRequestMetadataClientError.invalidResponse
        }

        guard payload.number == number,
              payload.number > 0,
              let headRef = nonEmpty(payload.head.ref),
              let headSHA = nonEmpty(payload.head.sha),
              let baseRef = nonEmpty(payload.base.ref),
              let baseSHA = nonEmpty(payload.base.sha),
              let updatedAt = parseGitHubDate(payload.updatedAt)
        else {
            throw GitHubPullRequestMetadataClientError.invalidResponse
        }

        let mergedAt: Date?
        if let rawMergedAt = nonEmpty(payload.mergedAt) {
            guard let parsedMergedAt = parseGitHubDate(rawMergedAt) else {
                throw GitHubPullRequestMetadataClientError.invalidResponse
            }
            mergedAt = parsedMergedAt
        } else {
            mergedAt = nil
        }

        let webURL = endpoints.webBaseURL
            .appendingPathComponent(repository.ownerLogin, isDirectory: true)
            .appendingPathComponent(repository.name, isDirectory: true)
            .appendingPathComponent("pull", isDirectory: true)
            .appendingPathComponent(String(number), isDirectory: false)

        return GitHubPullRequestMetadata(
            number: payload.number,
            state: GitHubPullRequestState(rawValue: payload.state),
            isDraft: payload.draft,
            isMerged: payload.merged,
            headRef: headRef,
            headSHA: headSHA,
            baseRef: baseRef,
            baseSHA: baseSHA,
            mergeCommitSHA: nonEmpty(payload.mergeCommitSHA),
            webURL: webURL,
            updatedAt: updatedAt,
            mergedAt: mergedAt
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

private struct PullRequestPayload: Decodable {
    let number: Int
    let state: String
    let draft: Bool
    let merged: Bool
    let mergeCommitSHA: String?
    let head: PullRequestRefPayload
    let base: PullRequestRefPayload
    let updatedAt: String
    let mergedAt: String?

    private enum CodingKeys: String, CodingKey {
        case number
        case state
        case draft
        case merged
        case mergeCommitSHA = "merge_commit_sha"
        case head
        case base
        case updatedAt = "updated_at"
        case mergedAt = "merged_at"
    }
}

private struct PullRequestRefPayload: Decodable {
    let ref: String
    let sha: String
}

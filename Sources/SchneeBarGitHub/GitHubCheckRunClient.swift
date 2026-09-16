import Foundation

public enum GitHubCheckRunStatus: Equatable, Sendable {
    case queued
    case inProgress
    case completed
    case waiting
    case requested
    case pending
    case unknown(String)

    init(rawValue: String) {
        switch rawValue {
        case "queued": self = .queued
        case "in_progress": self = .inProgress
        case "completed": self = .completed
        case "waiting": self = .waiting
        case "requested": self = .requested
        case "pending": self = .pending
        default: self = .unknown(rawValue)
        }
    }
}

public enum GitHubCheckRunConclusion: Equatable, Sendable {
    case actionRequired
    case cancelled
    case failure
    case neutral
    case success
    case skipped
    case stale
    case timedOut
    case unknown(String)

    init(rawValue: String) {
        switch rawValue {
        case "action_required": self = .actionRequired
        case "cancelled": self = .cancelled
        case "failure": self = .failure
        case "neutral": self = .neutral
        case "success": self = .success
        case "skipped": self = .skipped
        case "stale": self = .stale
        case "timed_out": self = .timedOut
        default: self = .unknown(rawValue)
        }
    }
}

public struct GitHubCheckRun: Identifiable, Equatable, Sendable {
    public let id: Int64
    public let name: String
    public let status: GitHubCheckRunStatus
    public let conclusion: GitHubCheckRunConclusion?
    public let appSlug: String?
    public let headSHA: String
    public let startedAt: Date?
    public let completedAt: Date?
    public let webURL: URL

    public init(
        id: Int64,
        name: String,
        status: GitHubCheckRunStatus,
        conclusion: GitHubCheckRunConclusion?,
        appSlug: String?,
        headSHA: String,
        startedAt: Date?,
        completedAt: Date?,
        webURL: URL
    ) {
        self.id = id
        self.name = name
        self.status = status
        self.conclusion = conclusion
        self.appSlug = appSlug
        self.headSHA = headSHA
        self.startedAt = startedAt
        self.completedAt = completedAt
        self.webURL = webURL
    }
}

public enum GitHubCheckRunClientError: Error, Equatable, Sendable {
    case invalidCredential
    case invalidRepository
    case invalidHeadSHA
    case invalidResponse
    case httpStatus(Int)
}

public struct GitHubCheckRunClient: Sendable {
    private let transport: any GitHubHTTPTransport

    public init(transport: any GitHubHTTPTransport = URLSessionGitHubHTTPTransport()) {
        self.transport = transport
    }

    public func checkRuns(
        repository: GitHubRepositoryAccess,
        headSHA: String,
        connection: GitHubConnection,
        credential: GitHubCredential
    ) async throws -> [GitHubCheckRun] {
        let token = credential.accessToken.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty else {
            throw GitHubCheckRunClientError.invalidCredential
        }
        guard !repository.ownerLogin.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !repository.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            throw GitHubCheckRunClientError.invalidRepository
        }
        let normalizedSHA = headSHA.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard isValidGitObjectID(normalizedSHA) else {
            throw GitHubCheckRunClientError.invalidHeadSHA
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
            .appendingPathComponent(normalizedSHA, isDirectory: true)
            .appendingPathComponent("check-runs", isDirectory: false)
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
            throw GitHubCheckRunClientError.httpStatus(response.statusCode)
        }

        let payload: CheckRunsPayload
        do {
            payload = try JSONDecoder().decode(CheckRunsPayload.self, from: data)
        } catch {
            throw GitHubCheckRunClientError.invalidResponse
        }

        return try payload.checkRuns.map {
            try map(
                $0,
                repository: repository,
                webBaseURL: endpoints.webBaseURL
            )
        }
    }

    private func requestURL(baseURL: URL) throws -> URL {
        guard var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false) else {
            throw GitHubCheckRunClientError.invalidResponse
        }
        components.queryItems = [URLQueryItem(name: "per_page", value: "100")]
        guard let url = components.url else {
            throw GitHubCheckRunClientError.invalidResponse
        }
        return url
    }

    private func map(
        _ payload: CheckRunPayload,
        repository: GitHubRepositoryAccess,
        webBaseURL: URL
    ) throws -> GitHubCheckRun {
        guard payload.id > 0,
              let name = nonEmpty(payload.name),
              let headSHA = nonEmpty(payload.headSHA)?.lowercased(),
              isValidGitObjectID(headSHA),
              let rawStatus = nonEmpty(payload.status)
        else {
            throw GitHubCheckRunClientError.invalidResponse
        }

        let startedAt = try parseOptionalGitHubDate(payload.startedAt)
        let completedAt = try parseOptionalGitHubDate(payload.completedAt)
        let webURL = webBaseURL
            .appendingPathComponent(repository.ownerLogin, isDirectory: true)
            .appendingPathComponent(repository.name, isDirectory: true)
            .appendingPathComponent("commit", isDirectory: true)
            .appendingPathComponent(headSHA, isDirectory: true)
            .appendingPathComponent("checks", isDirectory: false)

        return GitHubCheckRun(
            id: payload.id,
            name: name,
            status: GitHubCheckRunStatus(rawValue: rawStatus),
            conclusion: nonEmpty(payload.conclusion).map(GitHubCheckRunConclusion.init(rawValue:)),
            appSlug: nonEmpty(payload.app?.slug)?.lowercased(),
            headSHA: headSHA,
            startedAt: startedAt,
            completedAt: completedAt,
            webURL: webURL
        )
    }

    private func parseOptionalGitHubDate(_ value: String?) throws -> Date? {
        guard let value = nonEmpty(value) else { return nil }

        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: value) {
            return date
        }

        let standard = ISO8601DateFormatter()
        standard.formatOptions = [.withInternetDateTime]
        guard let date = standard.date(from: value) else {
            throw GitHubCheckRunClientError.invalidResponse
        }
        return date
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

    private func isValidGitObjectID(_ value: String) -> Bool {
        guard value.count == 40 || value.count == 64 else { return false }
        return value.unicodeScalars.allSatisfy { scalar in
            switch scalar.value {
            case 48 ... 57, 97 ... 102:
                true
            default:
                false
            }
        }
    }

    private func nonEmpty(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

private struct CheckRunsPayload: Decodable {
    let checkRuns: [CheckRunPayload]

    private enum CodingKeys: String, CodingKey {
        case checkRuns = "check_runs"
    }
}

private struct CheckRunPayload: Decodable {
    let id: Int64
    let name: String
    let status: String
    let conclusion: String?
    let headSHA: String
    let startedAt: String?
    let completedAt: String?
    let app: CheckRunAppPayload?

    private enum CodingKeys: String, CodingKey {
        case id
        case name
        case status
        case conclusion
        case headSHA = "head_sha"
        case startedAt = "started_at"
        case completedAt = "completed_at"
        case app
    }
}

private struct CheckRunAppPayload: Decodable {
    let slug: String?
}

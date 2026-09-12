import Foundation

public enum GitHubWorkflowJobStatus: Equatable, Sendable {
    case queued
    case inProgress
    case completed
    case waiting
    case pending
    case requested
    case unknown(String)

    init(rawValue: String) {
        switch rawValue {
        case "queued": self = .queued
        case "in_progress": self = .inProgress
        case "completed": self = .completed
        case "waiting": self = .waiting
        case "pending": self = .pending
        case "requested": self = .requested
        default: self = .unknown(rawValue)
        }
    }
}

public enum GitHubWorkflowJobConclusion: Equatable, Sendable {
    case success
    case failure
    case cancelled
    case skipped
    case timedOut
    case actionRequired
    case neutral
    case stale
    case startupFailure
    case unknown(String)

    init(rawValue: String) {
        switch rawValue {
        case "success": self = .success
        case "failure": self = .failure
        case "cancelled": self = .cancelled
        case "skipped": self = .skipped
        case "timed_out": self = .timedOut
        case "action_required": self = .actionRequired
        case "neutral": self = .neutral
        case "stale": self = .stale
        case "startup_failure": self = .startupFailure
        default: self = .unknown(rawValue)
        }
    }
}

public struct GitHubWorkflowJobStep: Equatable, Sendable {
    public let number: Int
    public let name: String
    public let status: GitHubWorkflowJobStatus
    public let conclusion: GitHubWorkflowJobConclusion?
    public let startedAt: Date?
    public let completedAt: Date?

    public init(
        number: Int,
        name: String,
        status: GitHubWorkflowJobStatus,
        conclusion: GitHubWorkflowJobConclusion?,
        startedAt: Date?,
        completedAt: Date?
    ) {
        self.number = number
        self.name = name
        self.status = status
        self.conclusion = conclusion
        self.startedAt = startedAt
        self.completedAt = completedAt
    }

    public var duration: TimeInterval? {
        guard let startedAt, let completedAt else { return nil }
        return max(0, completedAt.timeIntervalSince(startedAt))
    }
}

public struct GitHubWorkflowJob: Identifiable, Equatable, Sendable {
    public let id: Int64
    public let runID: Int64
    public let name: String
    public let status: GitHubWorkflowJobStatus
    public let conclusion: GitHubWorkflowJobConclusion?
    public let startedAt: Date?
    public let completedAt: Date?
    public let webURL: URL
    public let runnerName: String?
    public let runnerGroupName: String?
    public let labels: [String]
    public let steps: [GitHubWorkflowJobStep]

    public init(
        id: Int64,
        runID: Int64,
        name: String,
        status: GitHubWorkflowJobStatus,
        conclusion: GitHubWorkflowJobConclusion?,
        startedAt: Date?,
        completedAt: Date?,
        webURL: URL,
        runnerName: String?,
        runnerGroupName: String?,
        labels: [String],
        steps: [GitHubWorkflowJobStep]
    ) {
        self.id = id
        self.runID = runID
        self.name = name
        self.status = status
        self.conclusion = conclusion
        self.startedAt = startedAt
        self.completedAt = completedAt
        self.webURL = webURL
        self.runnerName = runnerName
        self.runnerGroupName = runnerGroupName
        self.labels = labels
        self.steps = steps
    }

    public var duration: TimeInterval? {
        guard let startedAt, let completedAt else { return nil }
        return max(0, completedAt.timeIntervalSince(startedAt))
    }
}

public enum GitHubWorkflowJobFilter: String, Sendable {
    case latest
    case all
}

public struct GitHubWorkflowJobQuery: Equatable, Sendable {
    public var filter: GitHubWorkflowJobFilter
    public var limit: Int

    public init(
        filter: GitHubWorkflowJobFilter = .latest,
        limit: Int = 100
    ) {
        self.filter = filter
        self.limit = limit
    }
}

public struct GitHubActionsJobsClient: Sendable {
    private static let maximumPages = 10
    private static let maximumResults = 500

    private let transport: any GitHubHTTPTransport

    public init(transport: any GitHubHTTPTransport = URLSessionGitHubHTTPTransport()) {
        self.transport = transport
    }

    public func jobs(
        runID: Int64,
        repository: GitHubRepositoryAccess,
        connection: GitHubConnection,
        credential: GitHubCredential,
        query: GitHubWorkflowJobQuery = .init()
    ) async throws -> [GitHubWorkflowJob] {
        let token = credential.accessToken.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty else {
            throw GitHubActionsClientError.invalidCredential
        }
        guard runID > 0 else {
            throw GitHubActionsClientError.invalidResponse
        }
        guard !repository.ownerLogin.isEmpty, !repository.name.isEmpty else {
            throw GitHubActionsClientError.invalidRepository
        }

        let requestedLimit = min(max(1, query.limit), Self.maximumResults)
        let endpoints = try GitHubEndpointResolver.resolve(
            deploymentKind: connection.deploymentKind,
            webBaseURL: connection.webBaseURL
        )
        let baseURL = endpoints.restBaseURL
            .appendingPathComponent("repos", isDirectory: true)
            .appendingPathComponent(repository.ownerLogin, isDirectory: true)
            .appendingPathComponent(repository.name, isDirectory: true)
            .appendingPathComponent("actions", isDirectory: true)
            .appendingPathComponent("runs", isDirectory: true)
            .appendingPathComponent(String(runID), isDirectory: true)
            .appendingPathComponent("jobs", isDirectory: false)

        var page = 1
        var expectedTotal: Int?
        var seenIDs = Set<Int64>()
        var jobs: [GitHubWorkflowJob] = []

        while jobs.count < requestedLimit,
              expectedTotal.map({ jobs.count < $0 }) ?? true
        {
            guard page <= Self.maximumPages else {
                throw GitHubActionsClientError.paginationLimitExceeded
            }

            let remaining = requestedLimit - jobs.count
            let url = try requestURL(
                baseURL: baseURL,
                page: page,
                perPage: min(100, remaining),
                query: query
            )
            let payload: WorkflowJobsPayload = try await get(
                url: url,
                connection: connection,
                token: token
            )
            expectedTotal = max(0, payload.totalCount)

            guard !payload.jobs.isEmpty else { break }

            let mapped = try payload.jobs.map {
                try mapJob(
                    $0,
                    expectedRunID: runID,
                    repository: repository,
                    webBaseURL: endpoints.webBaseURL
                )
            }
            let newJobs = mapped.filter { seenIDs.insert($0.id).inserted }
            guard !newJobs.isEmpty else { break }

            jobs.append(contentsOf: newJobs.prefix(remaining))
            page += 1
        }

        return jobs
    }

    private func get<Response: Decodable>(
        url: URL,
        connection: GitHubConnection,
        token: String
    ) async throws -> Response {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

        if let apiVersion = apiVersion(for: connection) {
            request.setValue(apiVersion, forHTTPHeaderField: "X-GitHub-Api-Version")
        }

        let (data, response) = try await transport.data(for: request)
        guard (200 ... 299).contains(response.statusCode) else {
            throw GitHubActionsClientError.httpStatus(response.statusCode)
        }

        do {
            return try JSONDecoder().decode(Response.self, from: data)
        } catch {
            throw GitHubActionsClientError.invalidResponse
        }
    }

    private func requestURL(
        baseURL: URL,
        page: Int,
        perPage: Int,
        query: GitHubWorkflowJobQuery
    ) throws -> URL {
        guard var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false) else {
            throw GitHubActionsClientError.invalidResponse
        }

        components.queryItems = [
            URLQueryItem(name: "filter", value: query.filter.rawValue),
            URLQueryItem(name: "per_page", value: String(perPage)),
            URLQueryItem(name: "page", value: String(page)),
        ]

        guard let url = components.url else {
            throw GitHubActionsClientError.invalidResponse
        }
        return url
    }

    private func mapJob(
        _ payload: WorkflowJobPayload,
        expectedRunID: Int64,
        repository: GitHubRepositoryAccess,
        webBaseURL: URL
    ) throws -> GitHubWorkflowJob {
        guard payload.id > 0,
              payload.runID == expectedRunID,
              !payload.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !payload.status.isEmpty
        else {
            throw GitHubActionsClientError.invalidResponse
        }

        let webURL = webBaseURL
            .appendingPathComponent(repository.ownerLogin, isDirectory: true)
            .appendingPathComponent(repository.name, isDirectory: true)
            .appendingPathComponent("actions", isDirectory: true)
            .appendingPathComponent("runs", isDirectory: true)
            .appendingPathComponent(String(expectedRunID), isDirectory: true)
            .appendingPathComponent("job", isDirectory: true)
            .appendingPathComponent(String(payload.id), isDirectory: false)

        let steps = try payload.steps.map(mapStep)

        return GitHubWorkflowJob(
            id: payload.id,
            runID: payload.runID,
            name: payload.name,
            status: GitHubWorkflowJobStatus(rawValue: payload.status),
            conclusion: payload.conclusion.map(GitHubWorkflowJobConclusion.init(rawValue:)),
            startedAt: try parseOptionalGitHubDate(payload.startedAt),
            completedAt: try parseOptionalGitHubDate(payload.completedAt),
            webURL: webURL,
            runnerName: nonEmpty(payload.runnerName),
            runnerGroupName: nonEmpty(payload.runnerGroupName),
            labels: payload.labels,
            steps: steps
        )
    }

    private func mapStep(_ payload: WorkflowJobStepPayload) throws -> GitHubWorkflowJobStep {
        guard payload.number > 0,
              !payload.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !payload.status.isEmpty
        else {
            throw GitHubActionsClientError.invalidResponse
        }

        return GitHubWorkflowJobStep(
            number: payload.number,
            name: payload.name,
            status: GitHubWorkflowJobStatus(rawValue: payload.status),
            conclusion: payload.conclusion.map(GitHubWorkflowJobConclusion.init(rawValue:)),
            startedAt: try parseOptionalGitHubDate(payload.startedAt),
            completedAt: try parseOptionalGitHubDate(payload.completedAt)
        )
    }

    private func parseOptionalGitHubDate(_ value: String?) throws -> Date? {
        guard let value = nonEmpty(value) else { return nil }
        guard let parsed = parseGitHubDate(value) else {
            throw GitHubActionsClientError.invalidResponse
        }
        return parsed
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

    private func apiVersion(for connection: GitHubConnection) -> String? {
        if let version = nonEmpty(connection.apiVersion) {
            return version
        }

        switch connection.deploymentKind {
        case .githubDotCom, .gheDotCom:
            return GitHubRESTAPIVersionPolicy.currentVersion
        case .enterpriseServer:
            return nil
        }
    }
}

private struct WorkflowJobsPayload: Decodable {
    let totalCount: Int
    let jobs: [WorkflowJobPayload]

    private enum CodingKeys: String, CodingKey {
        case totalCount = "total_count"
        case jobs
    }
}

private struct WorkflowJobPayload: Decodable {
    let id: Int64
    let runID: Int64
    let name: String
    let status: String
    let conclusion: String?
    let startedAt: String?
    let completedAt: String?
    let runnerName: String?
    let runnerGroupName: String?
    let labels: [String]
    let steps: [WorkflowJobStepPayload]

    private enum CodingKeys: String, CodingKey {
        case id
        case runID = "run_id"
        case name
        case status
        case conclusion
        case startedAt = "started_at"
        case completedAt = "completed_at"
        case runnerName = "runner_name"
        case runnerGroupName = "runner_group_name"
        case labels
        case steps
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(Int64.self, forKey: .id)
        runID = try container.decode(Int64.self, forKey: .runID)
        name = try container.decode(String.self, forKey: .name)
        status = try container.decode(String.self, forKey: .status)
        conclusion = try container.decodeIfPresent(String.self, forKey: .conclusion)
        startedAt = try container.decodeIfPresent(String.self, forKey: .startedAt)
        completedAt = try container.decodeIfPresent(String.self, forKey: .completedAt)
        runnerName = try container.decodeIfPresent(String.self, forKey: .runnerName)
        runnerGroupName = try container.decodeIfPresent(String.self, forKey: .runnerGroupName)
        labels = try container.decodeIfPresent([String].self, forKey: .labels) ?? []
        steps = try container.decodeIfPresent([WorkflowJobStepPayload].self, forKey: .steps) ?? []
    }
}

private struct WorkflowJobStepPayload: Decodable {
    let name: String
    let status: String
    let conclusion: String?
    let number: Int
    let startedAt: String?
    let completedAt: String?

    private enum CodingKeys: String, CodingKey {
        case name
        case status
        case conclusion
        case number
        case startedAt = "started_at"
        case completedAt = "completed_at"
    }
}

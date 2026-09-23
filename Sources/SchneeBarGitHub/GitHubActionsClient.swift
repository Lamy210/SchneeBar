import Foundation

public enum GitHubWorkflowRunStatus: Equatable, Sendable {
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

public enum GitHubWorkflowRunConclusion: Equatable, Sendable {
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

public struct GitHubWorkflowRun: Identifiable, Equatable, Sendable {
    public let id: Int64
    public let workflowID: Int64
    public let name: String
    public let displayTitle: String
    public let event: String
    public let status: GitHubWorkflowRunStatus
    public let conclusion: GitHubWorkflowRunConclusion?
    public let runNumber: Int
    public let headBranch: String?
    public let headSHA: String
    public let webURL: URL
    public let pullRequestNumbers: [Int]
    public let createdAt: Date
    public let updatedAt: Date

    public init(
        id: Int64,
        workflowID: Int64,
        name: String,
        displayTitle: String,
        event: String,
        status: GitHubWorkflowRunStatus,
        conclusion: GitHubWorkflowRunConclusion?,
        runNumber: Int,
        headBranch: String?,
        headSHA: String,
        webURL: URL,
        pullRequestNumbers: [Int],
        createdAt: Date,
        updatedAt: Date
    ) {
        self.id = id
        self.workflowID = workflowID
        self.name = name
        self.displayTitle = displayTitle
        self.event = event
        self.status = status
        self.conclusion = conclusion
        self.runNumber = runNumber
        self.headBranch = headBranch
        self.headSHA = headSHA
        self.webURL = webURL
        self.pullRequestNumbers = pullRequestNumbers
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

public enum GitHubWorkflowRunStatusFilter: String, Sendable {
    case completed
    case actionRequired = "action_required"
    case cancelled
    case failure
    case neutral
    case skipped
    case stale
    case success
    case timedOut = "timed_out"
    case inProgress = "in_progress"
    case queued
    case requested
    case waiting
    case pending
}

public struct GitHubWorkflowRunQuery: Equatable, Sendable {
    public var branch: String?
    public var event: String?
    public var status: GitHubWorkflowRunStatusFilter?
    public var limit: Int

    public init(
        branch: String? = nil,
        event: String? = nil,
        status: GitHubWorkflowRunStatusFilter? = nil,
        limit: Int = 50
    ) {
        self.branch = branch
        self.event = event
        self.status = status
        self.limit = limit
    }
}

public enum GitHubActionsClientError: Error, Equatable, Sendable {
    case invalidCredential
    case invalidRepository
    case invalidRunID
    case invalidResponse
    case httpStatus(Int)
    case paginationLimitExceeded
}

public struct GitHubActionsClient: Sendable {
    private static let maximumPages = 10
    private static let maximumResults = 500

    private let transport: any GitHubHTTPTransport

    public init(transport: any GitHubHTTPTransport = URLSessionGitHubHTTPTransport()) {
        self.transport = transport
    }

    public func workflowRun(
        id: Int64,
        repository: GitHubRepositoryAccess,
        connection: GitHubConnection,
        credential: GitHubCredential
    ) async throws -> GitHubWorkflowRun {
        guard id > 0 else {
            throw GitHubActionsClientError.invalidRunID
        }

        let token = credential.accessToken.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty else {
            throw GitHubActionsClientError.invalidCredential
        }
        guard !repository.ownerLogin.isEmpty, !repository.name.isEmpty else {
            throw GitHubActionsClientError.invalidRepository
        }

        let endpoints = try GitHubEndpointResolver.resolve(
            deploymentKind: connection.deploymentKind,
            webBaseURL: connection.webBaseURL
        )
        let url = endpoints.restBaseURL
            .appendingPathComponent("repos", isDirectory: true)
            .appendingPathComponent(repository.ownerLogin, isDirectory: true)
            .appendingPathComponent(repository.name, isDirectory: true)
            .appendingPathComponent("actions", isDirectory: true)
            .appendingPathComponent("runs", isDirectory: true)
            .appendingPathComponent(String(id), isDirectory: false)

        let payload: WorkflowRunPayload = try await get(
            url: url,
            connection: connection,
            token: token
        )
        return try mapRun(
            payload,
            repository: repository,
            webBaseURL: endpoints.webBaseURL
        )
    }

    public func workflowRuns(
        repository: GitHubRepositoryAccess,
        connection: GitHubConnection,
        credential: GitHubCredential,
        query: GitHubWorkflowRunQuery = .init()
    ) async throws -> [GitHubWorkflowRun] {
        let token = credential.accessToken.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty else {
            throw GitHubActionsClientError.invalidCredential
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
            .appendingPathComponent("runs", isDirectory: false)

        var page = 1
        var expectedTotal: Int?
        var seenIDs = Set<Int64>()
        var runs: [GitHubWorkflowRun] = []

        while runs.count < requestedLimit,
              expectedTotal.map({ runs.count < $0 }) ?? true
        {
            guard page <= Self.maximumPages else {
                throw GitHubActionsClientError.paginationLimitExceeded
            }

            let remaining = requestedLimit - runs.count
            let url = try requestURL(
                baseURL: baseURL,
                page: page,
                perPage: min(100, remaining),
                query: query
            )
            let payload: WorkflowRunsPayload = try await get(
                url: url,
                connection: connection,
                token: token
            )
            expectedTotal = max(0, payload.totalCount)

            guard !payload.workflowRuns.isEmpty else { break }

            let mapped = try payload.workflowRuns.map {
                try mapRun(
                    $0,
                    repository: repository,
                    webBaseURL: endpoints.webBaseURL
                )
            }
            let newRuns = mapped.filter { seenIDs.insert($0.id).inserted }
            guard !newRuns.isEmpty else { break }

            runs.append(contentsOf: newRuns.prefix(remaining))
            page += 1
        }

        return runs
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
        query: GitHubWorkflowRunQuery
    ) throws -> URL {
        guard var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false) else {
            throw GitHubActionsClientError.invalidResponse
        }

        var items = [
            URLQueryItem(name: "per_page", value: String(perPage)),
            URLQueryItem(name: "page", value: String(page)),
        ]

        if let branch = nonEmpty(query.branch) {
            items.append(URLQueryItem(name: "branch", value: branch))
        }
        if let event = nonEmpty(query.event) {
            items.append(URLQueryItem(name: "event", value: event))
        }
        if let status = query.status {
            items.append(URLQueryItem(name: "status", value: status.rawValue))
        }
        components.queryItems = items

        guard let url = components.url else {
            throw GitHubActionsClientError.invalidResponse
        }
        return url
    }

    private func mapRun(
        _ payload: WorkflowRunPayload,
        repository: GitHubRepositoryAccess,
        webBaseURL: URL
    ) throws -> GitHubWorkflowRun {
        guard payload.id > 0,
              payload.workflowID > 0,
              payload.runNumber > 0,
              !payload.event.isEmpty,
              !payload.status.isEmpty,
              !payload.headSHA.isEmpty,
              let createdAt = parseGitHubDate(payload.createdAt),
              let updatedAt = parseGitHubDate(payload.updatedAt)
        else {
            throw GitHubActionsClientError.invalidResponse
        }

        let fallbackName = "Workflow #\(payload.workflowID)"
        let name = nonEmpty(payload.name) ?? fallbackName
        let displayTitle = nonEmpty(payload.displayTitle) ?? name
        let webURL = webBaseURL
            .appendingPathComponent(repository.ownerLogin, isDirectory: true)
            .appendingPathComponent(repository.name, isDirectory: true)
            .appendingPathComponent("actions", isDirectory: true)
            .appendingPathComponent("runs", isDirectory: true)
            .appendingPathComponent(String(payload.id), isDirectory: false)

        return GitHubWorkflowRun(
            id: payload.id,
            workflowID: payload.workflowID,
            name: name,
            displayTitle: displayTitle,
            event: payload.event,
            status: GitHubWorkflowRunStatus(rawValue: payload.status),
            conclusion: payload.conclusion.map(GitHubWorkflowRunConclusion.init(rawValue:)),
            runNumber: payload.runNumber,
            headBranch: nonEmpty(payload.headBranch),
            headSHA: payload.headSHA,
            webURL: webURL,
            pullRequestNumbers: Array(Set(payload.pullRequests.map(\.number))).sorted(),
            createdAt: createdAt,
            updatedAt: updatedAt
        )
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

    private func apiVersion(
        for connection: GitHubConnection
    ) -> String? {
        GitHubRESTAPIVersionPolicy().headerVersion(for: connection)
    }
}

private struct WorkflowRunsPayload: Decodable {
    let totalCount: Int
    let workflowRuns: [WorkflowRunPayload]

    private enum CodingKeys: String, CodingKey {
        case totalCount = "total_count"
        case workflowRuns = "workflow_runs"
    }
}

private struct WorkflowRunPayload: Decodable {
    let id: Int64
    let workflowID: Int64
    let name: String?
    let displayTitle: String?
    let event: String
    let status: String
    let conclusion: String?
    let runNumber: Int
    let headBranch: String?
    let headSHA: String
    let pullRequests: [PullRequestReferencePayload]
    let createdAt: String
    let updatedAt: String

    private enum CodingKeys: String, CodingKey {
        case id
        case workflowID = "workflow_id"
        case name
        case displayTitle = "display_title"
        case event
        case status
        case conclusion
        case runNumber = "run_number"
        case headBranch = "head_branch"
        case headSHA = "head_sha"
        case pullRequests = "pull_requests"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
    }
}

private struct PullRequestReferencePayload: Decodable {
    let number: Int
}

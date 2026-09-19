import Foundation

public struct GitHubDeployment: Equatable, Sendable {
    public let id: Int64
    public let sha: String
    public let environment: String
    public let isProductionEnvironment: Bool
    public let isTransientEnvironment: Bool
    public let createdAt: Date?
    public let updatedAt: Date?

    public init(
        id: Int64,
        sha: String,
        environment: String,
        isProductionEnvironment: Bool,
        isTransientEnvironment: Bool,
        createdAt: Date?,
        updatedAt: Date?
    ) {
        self.id = id
        self.sha = sha
        self.environment = environment
        self.isProductionEnvironment = isProductionEnvironment
        self.isTransientEnvironment = isTransientEnvironment
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

public enum GitHubDeploymentStatusState: Equatable, Sendable {
    case pending
    case queued
    case inProgress
    case success
    case failure
    case error
    case inactive
    case unknown(String)

    init(rawValue: String) {
        let normalized = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        switch normalized.lowercased() {
        case "pending": self = .pending
        case "queued": self = .queued
        case "in_progress": self = .inProgress
        case "success": self = .success
        case "failure": self = .failure
        case "error": self = .error
        case "inactive": self = .inactive
        default: self = .unknown(normalized)
        }
    }
}

public struct GitHubDeploymentStatus: Equatable, Sendable {
    public let id: Int64
    public let state: GitHubDeploymentStatusState
    public let environment: String?
    public let description: String?
    public let environmentURL: URL?
    public let logURL: URL?
    public let createdAt: Date?
    public let updatedAt: Date?

    public init(
        id: Int64,
        state: GitHubDeploymentStatusState,
        environment: String?,
        description: String?,
        environmentURL: URL?,
        logURL: URL?,
        createdAt: Date?,
        updatedAt: Date?
    ) {
        self.id = id
        self.state = state
        self.environment = environment
        self.description = description
        self.environmentURL = environmentURL
        self.logURL = logURL
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

public enum GitHubDeploymentClientError: Error, Equatable, Sendable {
    case invalidCredential
    case invalidRepository
    case invalidSHA
    case invalidDeploymentID
    case invalidResponse
    case httpStatus(Int)
}

public struct GitHubDeploymentClient: Sendable {
    private static let maximumDeploymentLimit = 20

    private let transport: any GitHubHTTPTransport

    public init(transport: any GitHubHTTPTransport = URLSessionGitHubHTTPTransport()) {
        self.transport = transport
    }

    public func deployments(
        sha: String,
        repository: GitHubRepositoryAccess,
        connection: GitHubConnection,
        credential: GitHubCredential,
        limit: Int = 20
    ) async throws -> [GitHubDeployment] {
        let normalizedSHA = normalizedSHA(sha)
        guard !normalizedSHA.isEmpty else {
            throw GitHubDeploymentClientError.invalidSHA
        }
        try validate(repository: repository, credential: credential)

        let endpoints = try GitHubEndpointResolver.resolve(
            deploymentKind: connection.deploymentKind,
            webBaseURL: connection.webBaseURL
        )
        let baseURL = endpoints.restBaseURL
            .appendingPathComponent("repos", isDirectory: true)
            .appendingPathComponent(repository.ownerLogin, isDirectory: true)
            .appendingPathComponent(repository.name, isDirectory: true)
            .appendingPathComponent("deployments", isDirectory: false)

        guard var components = URLComponents(
            url: baseURL,
            resolvingAgainstBaseURL: false
        ) else {
            throw GitHubDeploymentClientError.invalidResponse
        }
        components.queryItems = [
            URLQueryItem(name: "sha", value: normalizedSHA),
            URLQueryItem(
                name: "per_page",
                value: String(min(max(1, limit), Self.maximumDeploymentLimit))
            ),
            URLQueryItem(name: "page", value: "1"),
        ]
        guard let url = components.url else {
            throw GitHubDeploymentClientError.invalidResponse
        }

        let payloads: [DeploymentPayload] = try await get(
            url: url,
            connection: connection,
            credential: credential
        )

        return try payloads.map { payload in
            guard payload.id > 0,
                  self.normalizedSHA(payload.sha) == normalizedSHA
            else {
                throw GitHubDeploymentClientError.invalidResponse
            }

            return GitHubDeployment(
                id: payload.id,
                sha: normalizedSHA,
                environment: payload.environment
                    .trimmingCharacters(in: .whitespacesAndNewlines),
                isProductionEnvironment: payload.productionEnvironment ?? false,
                isTransientEnvironment: payload.transientEnvironment ?? false,
                createdAt: try parseOptionalGitHubDate(payload.createdAt),
                updatedAt: try parseOptionalGitHubDate(payload.updatedAt)
            )
        }
    }

    public func latestStatus(
        deploymentID: Int64,
        repository: GitHubRepositoryAccess,
        connection: GitHubConnection,
        credential: GitHubCredential
    ) async throws -> GitHubDeploymentStatus? {
        guard deploymentID > 0 else {
            throw GitHubDeploymentClientError.invalidDeploymentID
        }
        try validate(repository: repository, credential: credential)

        let endpoints = try GitHubEndpointResolver.resolve(
            deploymentKind: connection.deploymentKind,
            webBaseURL: connection.webBaseURL
        )
        let baseURL = endpoints.restBaseURL
            .appendingPathComponent("repos", isDirectory: true)
            .appendingPathComponent(repository.ownerLogin, isDirectory: true)
            .appendingPathComponent(repository.name, isDirectory: true)
            .appendingPathComponent("deployments", isDirectory: true)
            .appendingPathComponent(String(deploymentID), isDirectory: true)
            .appendingPathComponent("statuses", isDirectory: false)

        guard var components = URLComponents(
            url: baseURL,
            resolvingAgainstBaseURL: false
        ) else {
            throw GitHubDeploymentClientError.invalidResponse
        }
        components.queryItems = [
            URLQueryItem(name: "per_page", value: "1"),
            URLQueryItem(name: "page", value: "1"),
        ]
        guard let url = components.url else {
            throw GitHubDeploymentClientError.invalidResponse
        }

        let payloads: [DeploymentStatusPayload] = try await get(
            url: url,
            connection: connection,
            credential: credential
        )
        guard let payload = payloads.first else {
            return nil
        }
        guard payload.id > 0 else {
            throw GitHubDeploymentClientError.invalidResponse
        }

        return GitHubDeploymentStatus(
            id: payload.id,
            state: GitHubDeploymentStatusState(rawValue: payload.state),
            environment: nonEmpty(payload.environment),
            description: nonEmpty(payload.description),
            environmentURL: safeExternalURL(payload.environmentURL),
            logURL: safeExternalURL(payload.logURL),
            createdAt: try parseOptionalGitHubDate(payload.createdAt),
            updatedAt: try parseOptionalGitHubDate(payload.updatedAt)
        )
    }

    private func validate(
        repository: GitHubRepositoryAccess,
        credential: GitHubCredential
    ) throws {
        guard !repository.ownerLogin
            .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !repository.name
                .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            throw GitHubDeploymentClientError.invalidRepository
        }

        guard !credential.accessToken
            .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            throw GitHubDeploymentClientError.invalidCredential
        }
    }

    private func get<Response: Decodable>(
        url: URL,
        connection: GitHubConnection,
        credential: GitHubCredential
    ) async throws -> Response {
        let token = credential.accessToken
            .trimmingCharacters(in: .whitespacesAndNewlines)

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        if let apiVersion = apiVersion(for: connection) {
            request.setValue(apiVersion, forHTTPHeaderField: "X-GitHub-Api-Version")
        }

        let (data, response) = try await transport.data(for: request)
        guard (200 ... 299).contains(response.statusCode) else {
            throw GitHubDeploymentClientError.httpStatus(response.statusCode)
        }

        do {
            return try JSONDecoder().decode(Response.self, from: data)
        } catch {
            throw GitHubDeploymentClientError.invalidResponse
        }
    }

    private func normalizedSHA(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private func nonEmpty(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private func parseOptionalGitHubDate(_ value: String?) throws -> Date? {
        guard let value = nonEmpty(value) else {
            return nil
        }
        guard let date = parseGitHubDate(value) else {
            throw GitHubDeploymentClientError.invalidResponse
        }
        return date
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

    private func safeExternalURL(_ rawValue: String?) -> URL? {
        guard let rawValue = nonEmpty(rawValue),
              let url = URL(string: rawValue),
              url.scheme?.lowercased() == "https",
              let host = url.host,
              !host.isEmpty,
              url.user == nil,
              url.password == nil
        else {
            return nil
        }
        return url
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

private struct DeploymentPayload: Decodable {
    let id: Int64
    let sha: String
    let environment: String
    let productionEnvironment: Bool?
    let transientEnvironment: Bool?
    let createdAt: String?
    let updatedAt: String?

    private enum CodingKeys: String, CodingKey {
        case id
        case sha
        case environment
        case productionEnvironment = "production_environment"
        case transientEnvironment = "transient_environment"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
    }
}

private struct DeploymentStatusPayload: Decodable {
    let id: Int64
    let state: String
    let environment: String?
    let description: String?
    let environmentURL: String?
    let logURL: String?
    let createdAt: String?
    let updatedAt: String?

    private enum CodingKeys: String, CodingKey {
        case id
        case state
        case environment
        case description
        case environmentURL = "environment_url"
        case logURL = "log_url"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
    }
}

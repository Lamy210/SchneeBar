import Foundation

public enum GitHubEnvironmentBranchPolicy: Equatable, Sendable {
    case allBranches
    case protectedBranches
    case customBranches
    case unknown
}

public struct GitHubEnvironmentProtection: Equatable, Sendable {
    public let waitTimerMinutes: Int?
    public let requiredReviewerCount: Int?
    public let preventsSelfReview: Bool?
    public let branchPolicy: GitHubEnvironmentBranchPolicy

    public init(
        waitTimerMinutes: Int?,
        requiredReviewerCount: Int?,
        preventsSelfReview: Bool?,
        branchPolicy: GitHubEnvironmentBranchPolicy
    ) {
        self.waitTimerMinutes = waitTimerMinutes
        self.requiredReviewerCount = requiredReviewerCount
        self.preventsSelfReview = preventsSelfReview
        self.branchPolicy = branchPolicy
    }
}

public struct GitHubEnvironment: Equatable, Sendable {
    public let id: Int64
    public let name: String
    public let protection: GitHubEnvironmentProtection
    public let createdAt: Date?
    public let updatedAt: Date?

    public init(
        id: Int64,
        name: String,
        protection: GitHubEnvironmentProtection,
        createdAt: Date?,
        updatedAt: Date?
    ) {
        self.id = id
        self.name = name
        self.protection = protection
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

public struct GitHubEnvironmentCatalog: Equatable, Sendable {
    public let totalCount: Int
    public let environments: [GitHubEnvironment]
    public let isTruncated: Bool

    public init(
        totalCount: Int,
        environments: [GitHubEnvironment],
        isTruncated: Bool
    ) {
        self.totalCount = totalCount
        self.environments = environments
        self.isTruncated = isTruncated
    }
}

public enum GitHubEnvironmentClientError: Error, Equatable, Sendable {
    case invalidCredential
    case invalidRepository
    case invalidResponse
    case httpStatus(Int)
}

public struct GitHubEnvironmentClient: Sendable {
    private static let maximumEnvironmentLimit = 100

    private let transport: any GitHubHTTPTransport

    public init(
        transport: any GitHubHTTPTransport = URLSessionGitHubHTTPTransport()
    ) {
        self.transport = transport
    }

    public func environments(
        repository: GitHubRepositoryAccess,
        connection: GitHubConnection,
        credential: GitHubCredential,
        limit: Int = 100
    ) async throws -> GitHubEnvironmentCatalog {
        try validate(repository: repository, credential: credential)

        let endpoints = try GitHubEndpointResolver.resolve(
            deploymentKind: connection.deploymentKind,
            webBaseURL: connection.webBaseURL
        )
        let baseURL = endpoints.restBaseURL
            .appendingPathComponent("repos", isDirectory: true)
            .appendingPathComponent(repository.ownerLogin, isDirectory: true)
            .appendingPathComponent(repository.name, isDirectory: true)
            .appendingPathComponent("environments", isDirectory: false)

        guard var components = URLComponents(
            url: baseURL,
            resolvingAgainstBaseURL: false
        ) else {
            throw GitHubEnvironmentClientError.invalidResponse
        }

        let clampedLimit = min(
            max(1, limit),
            Self.maximumEnvironmentLimit
        )
        components.queryItems = [
            URLQueryItem(
                name: "per_page",
                value: String(clampedLimit)
            ),
            URLQueryItem(name: "page", value: "1"),
        ]

        guard let url = components.url else {
            throw GitHubEnvironmentClientError.invalidResponse
        }

        let payload: EnvironmentListPayload = try await get(
            url: url,
            connection: connection,
            credential: credential
        )

        guard payload.totalCount >= 0,
              payload.totalCount >= payload.environments.count
        else {
            throw GitHubEnvironmentClientError.invalidResponse
        }

        let environments = try payload.environments.map(mapEnvironment)

        return GitHubEnvironmentCatalog(
            totalCount: payload.totalCount,
            environments: environments,
            isTruncated: payload.totalCount > environments.count
        )
    }

    private func mapEnvironment(
        _ payload: EnvironmentPayload
    ) throws -> GitHubEnvironment {
        guard payload.id > 0,
              let name = nonEmpty(payload.name)
        else {
            throw GitHubEnvironmentClientError.invalidResponse
        }

        let waitRules = payload.protectionRules.filter {
            normalizedRuleType($0.type) == "wait_timer"
        }
        guard waitRules.count <= 1 else {
            throw GitHubEnvironmentClientError.invalidResponse
        }

        let reviewerRules = payload.protectionRules.filter {
            normalizedRuleType($0.type) == "required_reviewers"
        }
        guard reviewerRules.count <= 1 else {
            throw GitHubEnvironmentClientError.invalidResponse
        }

        let waitTimerMinutes = waitRules.first?.waitTimer
        if let waitTimerMinutes, waitTimerMinutes < 0 {
            throw GitHubEnvironmentClientError.invalidResponse
        }

        let reviewerRule = reviewerRules.first
        let requiredReviewerCount = reviewerRule?.reviewers?.count
        let preventsSelfReview = reviewerRule?.preventSelfReview

        return GitHubEnvironment(
            id: payload.id,
            name: name,
            protection: GitHubEnvironmentProtection(
                waitTimerMinutes: waitTimerMinutes,
                requiredReviewerCount: requiredReviewerCount,
                preventsSelfReview: preventsSelfReview,
                branchPolicy: branchPolicy(
                    payload: payload.deploymentBranchPolicy,
                    keyWasPresent: payload.deploymentBranchPolicyWasPresent
                )
            ),
            createdAt: parseOptionalGitHubDate(payload.createdAt),
            updatedAt: parseOptionalGitHubDate(payload.updatedAt)
        )
    }

    private func validate(
        repository: GitHubRepositoryAccess,
        credential: GitHubCredential
    ) throws {
        guard nonEmpty(repository.ownerLogin) != nil,
              nonEmpty(repository.name) != nil
        else {
            throw GitHubEnvironmentClientError.invalidRepository
        }

        guard nonEmpty(credential.accessToken) != nil else {
            throw GitHubEnvironmentClientError.invalidCredential
        }
    }

    private func get<Response: Decodable>(
        url: URL,
        connection: GitHubConnection,
        credential: GitHubCredential
    ) async throws -> Response {
        guard let token = nonEmpty(credential.accessToken) else {
            throw GitHubEnvironmentClientError.invalidCredential
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue(
            "application/vnd.github+json",
            forHTTPHeaderField: "Accept"
        )
        request.setValue(
            "Bearer \(token)",
            forHTTPHeaderField: "Authorization"
        )
        if let apiVersion = apiVersion(for: connection) {
            request.setValue(
                apiVersion,
                forHTTPHeaderField: "X-GitHub-Api-Version"
            )
        }

        let (data, response) = try await transport.data(for: request)
        guard (200 ... 299).contains(response.statusCode) else {
            throw GitHubEnvironmentClientError.httpStatus(response.statusCode)
        }

        do {
            return try JSONDecoder().decode(Response.self, from: data)
        } catch let error as GitHubEnvironmentClientError {
            throw error
        } catch {
            throw GitHubEnvironmentClientError.invalidResponse
        }
    }

    private func branchPolicy(
        payload: DeploymentBranchPolicyPayload?,
        keyWasPresent: Bool
    ) -> GitHubEnvironmentBranchPolicy {
        guard keyWasPresent else {
            return .unknown
        }
        guard let payload else {
            return .allBranches
        }

        switch (
            payload.protectedBranches,
            payload.customBranchPolicies
        ) {
        case (true?, false?):
            return .protectedBranches
        case (false?, true?):
            return .customBranches
        default:
            return .unknown
        }
    }

    private func normalizedRuleType(_ value: String) -> String {
        value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
    }

    private func nonEmpty(_ value: String?) -> String? {
        guard let value else {
            return nil
        }
        let trimmed = value
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private func parseOptionalGitHubDate(_ value: String?) -> Date? {
        guard let value = nonEmpty(value) else {
            return nil
        }

        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [
            .withInternetDateTime,
            .withFractionalSeconds,
        ]
        if let date = fractional.date(from: value) {
            return date
        }

        let standard = ISO8601DateFormatter()
        standard.formatOptions = [.withInternetDateTime]
        return standard.date(from: value)
    }

    private func apiVersion(
        for connection: GitHubConnection
    ) -> String? {
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

private struct EnvironmentListPayload: Decodable {
    let totalCount: Int
    let environments: [EnvironmentPayload]

    private enum CodingKeys: String, CodingKey {
        case totalCount = "total_count"
        case environments
    }
}

private struct EnvironmentPayload: Decodable {
    let id: Int64
    let name: String
    let protectionRules: [ProtectionRulePayload]
    let deploymentBranchPolicy: DeploymentBranchPolicyPayload?
    let deploymentBranchPolicyWasPresent: Bool
    let createdAt: String?
    let updatedAt: String?

    private enum CodingKeys: String, CodingKey {
        case id
        case name
        case protectionRules = "protection_rules"
        case deploymentBranchPolicy = "deployment_branch_policy"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(
            keyedBy: CodingKeys.self
        )

        id = try container.decode(Int64.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        protectionRules = try container.decodeIfPresent(
            [ProtectionRulePayload].self,
            forKey: .protectionRules
        ) ?? []
        deploymentBranchPolicyWasPresent = container.contains(
            .deploymentBranchPolicy
        )
        deploymentBranchPolicy = try container.decodeIfPresent(
            DeploymentBranchPolicyPayload.self,
            forKey: .deploymentBranchPolicy
        )
        createdAt = try container.decodeIfPresent(
            String.self,
            forKey: .createdAt
        )
        updatedAt = try container.decodeIfPresent(
            String.self,
            forKey: .updatedAt
        )
    }
}

private struct ProtectionRulePayload: Decodable {
    let type: String
    let waitTimer: Int?
    let preventSelfReview: Bool?
    let reviewers: [ReviewerPayload]?

    private enum CodingKeys: String, CodingKey {
        case type
        case waitTimer = "wait_timer"
        case preventSelfReview = "prevent_self_review"
        case reviewers
    }
}

private struct ReviewerPayload: Decodable {}

private struct DeploymentBranchPolicyPayload: Decodable {
    let protectedBranches: Bool?
    let customBranchPolicies: Bool?

    private enum CodingKeys: String, CodingKey {
        case protectedBranches = "protected_branches"
        case customBranchPolicies = "custom_branch_policies"
    }
}

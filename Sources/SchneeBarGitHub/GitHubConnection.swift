import Foundation

public enum GitHubDeploymentKind: String, Codable, CaseIterable, Sendable {
    case githubDotCom
    case gheDotCom
    case enterpriseServer
}

public struct GitHubConnection: Identifiable, Codable, Equatable, Sendable {
    public let id: UUID
    public var displayName: String
    public let deploymentKind: GitHubDeploymentKind
    public let webBaseURL: URL
    /// Latest GHES version discovered by the provider boundary.
    /// Use `applyDiscoveredServerVersion` so derived API-version policy stays in sync.
    public private(set) var serverVersion: String?
    public var apiVersion: String?

    private enum CodingKeys: String, CodingKey {
        case id
        case displayName
        case deploymentKind
        case webBaseURL
        case serverVersion
        case apiVersion
    }

    public init(
        id: UUID = UUID(),
        displayName: String,
        deploymentKind: GitHubDeploymentKind,
        webBaseURL: URL,
        serverVersion: String? = nil,
        apiVersion: String? = nil
    ) {
        self.id = id
        self.displayName = displayName
        self.deploymentKind = deploymentKind
        self.webBaseURL = webBaseURL
        self.serverVersion = Self.normalizedServerVersion(
            serverVersion,
            deploymentKind: deploymentKind
        )
        if let apiVersion {
            self.apiVersion = apiVersion
        } else if deploymentKind == .enterpriseServer {
            self.apiVersion = Self.preferredEnterpriseAPIVersion(
                for: self.serverVersion
            )
        } else {
            self.apiVersion = nil
        }
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        displayName = try container.decode(String.self, forKey: .displayName)
        deploymentKind = try container.decode(
            GitHubDeploymentKind.self,
            forKey: .deploymentKind
        )
        webBaseURL = try container.decode(URL.self, forKey: .webBaseURL)
        let decodedServerVersion = try container.decodeIfPresent(
            String.self,
            forKey: .serverVersion
        )
        serverVersion = Self.normalizedServerVersion(
            decodedServerVersion,
            deploymentKind: deploymentKind
        )
        // Preserve explicit/custom persisted overrides exactly. Validation of
        // that separate request-header boundary is intentionally out of scope
        // for GHES version presentation normalization.
        apiVersion = try container.decodeIfPresent(
            String.self,
            forKey: .apiVersion
        )
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(displayName, forKey: .displayName)
        try container.encode(deploymentKind, forKey: .deploymentKind)
        try container.encode(webBaseURL, forKey: .webBaseURL)
        try container.encodeIfPresent(serverVersion, forKey: .serverVersion)
        try container.encodeIfPresent(apiVersion, forKey: .apiVersion)
    }

    public mutating func applyDiscoveredServerVersion(
        _ discoveredVersion: String?
    ) {
        guard deploymentKind == .enterpriseServer else {
            return
        }

        let previouslyDerivedVersion = Self.preferredEnterpriseAPIVersion(
            for: serverVersion
        )
        let shouldRefreshDerivedVersion = apiVersion == nil
            || apiVersion == previouslyDerivedVersion
        let normalizedVersion = Self.normalizedServerVersion(
            discoveredVersion,
            deploymentKind: deploymentKind
        )

        serverVersion = normalizedVersion

        if shouldRefreshDerivedVersion {
            apiVersion = Self.preferredEnterpriseAPIVersion(
                for: normalizedVersion
            )
        }
    }

    private static func normalizedServerVersion(
        _ serverVersion: String?,
        deploymentKind: GitHubDeploymentKind
    ) -> String? {
        guard deploymentKind == .enterpriseServer else {
            return serverVersion
        }
        return GitHubEnterpriseServerVersionPresentationPolicy
            .normalizedPersistedValue(serverVersion)
    }

    private static func preferredEnterpriseAPIVersion(
        for serverVersion: String?
    ) -> String? {
        let parsedVersion = serverVersion.flatMap(
            GitHubEnterpriseServerVersion.init(parsing:)
        )
        return GitHubRESTAPIVersionPolicy().preferredVersion(
            for: parsedVersion
        )
    }
}

public struct GitHubEndpointSet: Equatable, Sendable {
    public let webBaseURL: URL
    public let restBaseURL: URL
    public let graphQLURL: URL
    public let authenticationBaseURL: URL

    public init(
        webBaseURL: URL,
        restBaseURL: URL,
        graphQLURL: URL,
        authenticationBaseURL: URL
    ) {
        self.webBaseURL = webBaseURL
        self.restBaseURL = restBaseURL
        self.graphQLURL = graphQLURL
        self.authenticationBaseURL = authenticationBaseURL
    }
}

public enum GitHubCapability: String, Codable, CaseIterable, Hashable, Sendable {
    case actions
    case pullRequests
    case checks
    case deployments
    case releases
    case mergeQueue
    case securityAlerts
    case workflowWrite
}

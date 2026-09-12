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
    public var serverVersion: String?
    public var apiVersion: String?

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
        self.serverVersion = serverVersion
        self.apiVersion = apiVersion
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

public struct GitHubCapabilitySet: Codable, Equatable, Sendable {
    public var supported: Set<GitHubCapability>

    public init(supported: Set<GitHubCapability> = []) {
        self.supported = supported
    }

    public func supports(_ capability: GitHubCapability) -> Bool {
        supported.contains(capability)
    }
}

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
    public var serverVersion: String? {
        didSet {
            guard deploymentKind == .enterpriseServer,
                  apiVersion == nil
            else {
                return
            }
            apiVersion = Self.preferredEnterpriseAPIVersion(for: serverVersion)
        }
    }
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
        if let apiVersion {
            self.apiVersion = apiVersion
        } else if deploymentKind == .enterpriseServer {
            self.apiVersion = Self.preferredEnterpriseAPIVersion(for: serverVersion)
        } else {
            self.apiVersion = nil
        }
    }

    private static func preferredEnterpriseAPIVersion(
        for serverVersion: String?
    ) -> String? {
        let parsedVersion = serverVersion.flatMap(GitHubEnterpriseServerVersion.init(parsing:))
        return GitHubRESTAPIVersionPolicy().preferredVersion(for: parsedVersion)
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

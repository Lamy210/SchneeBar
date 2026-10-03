import Foundation

public struct GitHubConnectionProfileSemanticIdentity: Equatable, Hashable, Sendable {
    public let deploymentKind: GitHubDeploymentKind
    public let canonicalWebBaseURL: String
    public let accountID: String

    public init?(
        connection: GitHubConnection,
        accountID: String
    ) {
        guard let endpoints = try? GitHubEndpointResolver.resolve(
            deploymentKind: connection.deploymentKind,
            webBaseURL: connection.webBaseURL
        ) else {
            return nil
        }

        self.deploymentKind = connection.deploymentKind
        self.canonicalWebBaseURL = endpoints.webBaseURL.absoluteString
        self.accountID = accountID
    }

    public init?(profile: GitHubConnectionProfile) {
        self.init(
            connection: profile.connection,
            accountID: profile.account.id
        )
    }

    public static func == (
        lhs: GitHubConnectionProfileSemanticIdentity,
        rhs: GitHubConnectionProfileSemanticIdentity
    ) -> Bool {
        lhs.deploymentKind.rawValue == rhs.deploymentKind.rawValue
            && lhs.canonicalWebBaseURL == rhs.canonicalWebBaseURL
            && lhs.accountID == rhs.accountID
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(deploymentKind.rawValue)
        hasher.combine(canonicalWebBaseURL)
        hasher.combine(accountID)
    }
}

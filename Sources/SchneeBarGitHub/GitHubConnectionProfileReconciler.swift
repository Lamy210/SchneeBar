import Foundation

public struct GitHubConnectionProfileReconciler: Sendable {
    public init() {}

    public func reconcile(
        existingProfiles: [GitHubConnectionProfile],
        authenticatedConnection: GitHubConnection,
        account: GitHubAccountIdentity,
        authenticationMethod: GitHubAuthenticationMethod,
        clientID: String?,
        now: Date
    ) -> GitHubConnectionProfile {
        guard let existing = matchingProfile(
            in: existingProfiles,
            connection: authenticatedConnection,
            account: account
        ) else {
            return GitHubConnectionProfile(
                connection: authenticatedConnection,
                account: account,
                authenticationMethod: authenticationMethod,
                clientID: clientID,
                repositorySelection: .allAccessible,
                isEnabled: true,
                createdAt: now,
                lastConnectedAt: now
            )
        }

        let reboundConnection = GitHubConnection(
            id: existing.id,
            displayName: authenticatedConnection.displayName,
            deploymentKind: authenticatedConnection.deploymentKind,
            webBaseURL: authenticatedConnection.webBaseURL,
            serverVersion: authenticatedConnection.serverVersion,
            apiVersion: authenticatedConnection.apiVersion
        )

        return GitHubConnectionProfile(
            connection: reboundConnection,
            account: account,
            authenticationMethod: authenticationMethod,
            clientID: clientID,
            repositorySelection: existing.repositorySelection,
            isEnabled: existing.isEnabled,
            createdAt: existing.createdAt,
            lastConnectedAt: now
        )
    }

    private func matchingProfile(
        in profiles: [GitHubConnectionProfile],
        connection: GitHubConnection,
        account: GitHubAccountIdentity
    ) -> GitHubConnectionProfile? {
        guard let endpoint = endpointIdentity(for: connection) else {
            return nil
        }

        return profiles
            .filter { profile in
                profile.account.id == account.id
                    && endpointIdentity(for: profile.connection) == endpoint
            }
            .sorted { lhs, rhs in
                if lhs.createdAt != rhs.createdAt {
                    return lhs.createdAt < rhs.createdAt
                }
                return lhs.id.uuidString < rhs.id.uuidString
            }
            .first
    }

    private func endpointIdentity(
        for connection: GitHubConnection
    ) -> EndpointIdentity? {
        guard let endpoints = try? GitHubEndpointResolver.resolve(
            deploymentKind: connection.deploymentKind,
            webBaseURL: connection.webBaseURL
        ) else {
            return nil
        }

        return EndpointIdentity(
            deploymentKind: connection.deploymentKind,
            canonicalWebBaseURL: endpoints.webBaseURL.absoluteString
        )
    }

    private struct EndpointIdentity: Equatable {
        let deploymentKind: GitHubDeploymentKind
        let canonicalWebBaseURL: String
    }
}

public enum GitHubConnectionProfileOrdering {
    public static func sorted(
        _ profiles: [GitHubConnectionProfile]
    ) -> [GitHubConnectionProfile] {
        profiles.sorted(by: isOrderedBefore)
    }

    private static func isOrderedBefore(
        _ lhs: GitHubConnectionProfile,
        _ rhs: GitHubConnectionProfile
    ) -> Bool {
        let lhsName = lhs.connection.displayName.lowercased()
        let rhsName = rhs.connection.displayName.lowercased()
        if lhsName != rhsName {
            return lhsName < rhsName
        }

        let lhsEndpoint = canonicalEndpoint(lhs.connection)
        let rhsEndpoint = canonicalEndpoint(rhs.connection)
        if lhsEndpoint != rhsEndpoint {
            return lhsEndpoint < rhsEndpoint
        }

        let lhsLogin = lhs.account.login.lowercased()
        let rhsLogin = rhs.account.login.lowercased()
        if lhsLogin != rhsLogin {
            return lhsLogin < rhsLogin
        }

        return lhs.id.uuidString < rhs.id.uuidString
    }

    private static func canonicalEndpoint(_ connection: GitHubConnection) -> String {
        guard let endpoints = try? GitHubEndpointResolver.resolve(
            deploymentKind: connection.deploymentKind,
            webBaseURL: connection.webBaseURL
        ) else {
            return connection.webBaseURL.absoluteString.lowercased()
        }
        return "\(connection.deploymentKind.rawValue)|\(endpoints.webBaseURL.absoluteString)"
    }
}

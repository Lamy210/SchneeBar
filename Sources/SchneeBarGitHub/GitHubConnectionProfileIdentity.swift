import Foundation

public struct GitHubConnectionProfileIdentity: Equatable, Hashable, Sendable {
    public let deploymentKind: String
    public let canonicalWebBaseURL: String
    public let accountID: String

    public init(
        deploymentKind: String,
        canonicalWebBaseURL: String,
        accountID: String
    ) {
        self.deploymentKind = deploymentKind
        self.canonicalWebBaseURL = canonicalWebBaseURL
        self.accountID = accountID
    }
}

public enum GitHubConnectionProfileIdentityPolicy {
    public static func identity(
        for profile: GitHubConnectionProfile
    ) -> GitHubConnectionProfileIdentity? {
        identity(
            connection: profile.connection,
            accountID: profile.account.id
        )
    }

    public static func identity(
        connection: GitHubConnection,
        accountID: String
    ) -> GitHubConnectionProfileIdentity? {
        guard let endpoints = try? GitHubEndpointResolver.resolve(
            deploymentKind: connection.deploymentKind,
            webBaseURL: connection.webBaseURL
        ) else {
            return nil
        }

        return GitHubConnectionProfileIdentity(
            deploymentKind: connection.deploymentKind.rawValue,
            canonicalWebBaseURL: endpoints.webBaseURL.absoluteString,
            accountID: accountID
        )
    }

    public static func conflictingProfileID(
        for profile: GitHubConnectionProfile,
        in profiles: [GitHubConnectionProfile]
    ) -> UUID? {
        guard let expected = identity(for: profile) else {
            return nil
        }

        return profiles
            .filter {
                $0.id != profile.id
                    && identity(for: $0) == expected
            }
            .map(\.id)
            .sorted { $0.uuidString < $1.uuidString }
            .first
    }

    public static func ambiguousProfileIDs(
        in profiles: [GitHubConnectionProfile]
    ) -> Set<UUID> {
        var firstIDByIdentity: [
            GitHubConnectionProfileIdentity: UUID
        ] = [:]
        var seenConnectionIDs: Set<UUID> = []
        var ambiguousIDs: Set<UUID> = []

        for profile in profiles {
            if !seenConnectionIDs.insert(profile.id).inserted {
                ambiguousIDs.insert(profile.id)
            }

            guard let profileIdentity = identity(for: profile) else {
                continue
            }

            if let firstID = firstIDByIdentity[profileIdentity] {
                ambiguousIDs.insert(firstID)
                ambiguousIDs.insert(profile.id)
            } else {
                firstIDByIdentity[profileIdentity] = profile.id
            }
        }

        return ambiguousIDs
    }
}

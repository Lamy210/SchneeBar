import Foundation

public struct GitHubRESTAPIVersionPolicy: Sendable {
    public static let legacyVersion = "2022-11-28"
    public static let currentVersion = "2026-03-10"

    public init() {}

    public func preferredVersion(
        for enterpriseVersion: GitHubEnterpriseServerVersion?
    ) -> String? {
        guard let enterpriseVersion else { return nil }

        let firstCurrentAPIVersionRelease = GitHubEnterpriseServerVersion(
            major: 3,
            minor: 21
        )

        if enterpriseVersion >= firstCurrentAPIVersionRelease {
            return Self.currentVersion
        }

        return Self.legacyVersion
    }
}

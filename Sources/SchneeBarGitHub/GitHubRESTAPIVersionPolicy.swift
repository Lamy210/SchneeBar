import Foundation

public struct GitHubRESTAPIVersionPolicy: Sendable {
    public static let legacyVersion = "2022-11-28"
    public static let currentVersion = "2026-03-10"

    public init() {}

    public func headerVersion(for connection: GitHubConnection) -> String? {
        if let configured = normalized(connection.apiVersion) {
            return configured
        }

        switch connection.deploymentKind {
        case .githubDotCom, .gheDotCom:
            return Self.currentVersion
        case .enterpriseServer:
            let enterpriseVersion = connection.serverVersion.flatMap(
                GitHubEnterpriseServerVersion.init(parsing:)
            )
            return preferredVersion(for: enterpriseVersion)
        }
    }

    private func normalized(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    public func preferredVersion(
        for enterpriseVersion: GitHubEnterpriseServerVersion?
    ) -> String? {
        guard let enterpriseVersion else { return nil }

        guard enterpriseVersion.major == 3 else {
            return nil
        }

        switch enterpriseVersion.minor {
        case 20:
            return Self.legacyVersion
        case 21 ... 22:
            return Self.currentVersion
        default:
            // Do not invent a date-based API version for GHES releases
            // outside SchneeBar's evidence-backed compatibility matrix.
            return nil
        }
    }
}

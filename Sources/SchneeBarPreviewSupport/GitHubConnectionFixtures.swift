import Foundation
import SchneeBarGitHubFeature

public enum GitHubConnectionsFixture: String, CaseIterable, Sendable {
    case empty
    case multiConnection
    case needsAttention

    public var connections: [GitHubConnectionCardModel] {
        switch self {
        case .empty:
            return []

        case .multiConnection:
            return [
                GitHubConnectionCardModel(
                    id: UUID(uuidString: "20000000-0000-0000-0000-000000000001")!,
                    displayName: "Personal GitHub",
                    host: "github.com",
                    accountLogin: "Lamy210",
                    deploymentLabel: "GitHub.com",
                    repositorySelectionLabel: "14 repositories",
                    status: .connected(repositoryCount: 14),
                    isEnabled: true
                ),
                GitHubConnectionCardModel(
                    id: UUID(uuidString: "20000000-0000-0000-0000-000000000002")!,
                    displayName: "Company Cloud",
                    host: "company.ghe.com",
                    accountLogin: "lamy_company",
                    deploymentLabel: "GHE.com",
                    repositorySelectionLabel: "22 repositories",
                    status: .ssoRequired,
                    isEnabled: true
                ),
                GitHubConnectionCardModel(
                    id: UUID(uuidString: "20000000-0000-0000-0000-000000000003")!,
                    displayName: "Internal GitHub",
                    host: "github.internal.example:8443",
                    accountLogin: "lamy",
                    deploymentLabel: "GHES 3.22",
                    repositorySelectionLabel: "Selected repositories",
                    status: .connected(repositoryCount: 48),
                    isEnabled: true
                ),
            ]

        case .needsAttention:
            return [
                GitHubConnectionCardModel(
                    id: UUID(uuidString: "20000000-0000-0000-0000-000000000010")!,
                    displayName: "Company GitHub",
                    host: "github.company.internal",
                    accountLogin: "lamy",
                    deploymentLabel: "GHES 3.19",
                    repositorySelectionLabel: "31 repositories",
                    status: .untestedServer(version: "3.19"),
                    isEnabled: true
                ),
                GitHubConnectionCardModel(
                    id: UUID(uuidString: "20000000-0000-0000-0000-000000000011")!,
                    displayName: "VPN GitHub",
                    host: "github.private.example",
                    accountLogin: "lamy",
                    deploymentLabel: "GitHub Enterprise Server",
                    repositorySelectionLabel: "Last synced 18m ago",
                    status: .networkUnavailable,
                    isEnabled: true
                ),
                GitHubConnectionCardModel(
                    id: UUID(uuidString: "20000000-0000-0000-0000-000000000012")!,
                    displayName: "Legacy Organization",
                    host: "github.com",
                    accountLogin: "Lamy210",
                    deploymentLabel: "GitHub.com",
                    repositorySelectionLabel: "Monitoring disabled",
                    status: .authenticationRequired,
                    isEnabled: false
                ),
            ]
        }
    }
}

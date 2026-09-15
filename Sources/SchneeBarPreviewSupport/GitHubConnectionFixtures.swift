import Foundation
import SchneeBarGitHubFeature

public enum GitHubConnectionsFixture: String, CaseIterable, Hashable, Sendable {
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
                    id: UUID(uuidString: "20000000-0000-0000-0000-000000000004")!,
                    displayName: "Work GitHub",
                    host: "github.com",
                    accountLogin: "lamy-work",
                    deploymentLabel: "GitHub.com",
                    repositorySelectionLabel: "6 selected repositories",
                    status: .connected(repositoryCount: 18),
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

public enum GitHubConnectionManagementFixture {
    public static let model = GitHubConnectionManagementModel(
        id: UUID(uuidString: "21000000-0000-0000-0000-000000000001")!,
        displayName: "Internal GitHub",
        host: "github.internal.example:8443",
        accountLogin: "lamy",
        repositories: [
            GitHubRepositoryOptionModel(
                id: 101,
                fullName: "SchneeOrg/api-gateway",
                isPrivate: true,
                actionsAccess: .unavailable
            ),
            GitHubRepositoryOptionModel(
                id: 102,
                fullName: "SchneeOrg/authentication-platform",
                isPrivate: true,
                actionsAccess: .available
            ),
            GitHubRepositoryOptionModel(
                id: 103,
                fullName: "SchneeOrg/design-system",
                isPrivate: false,
                actionsAccess: .unavailable
            ),
            GitHubRepositoryOptionModel(
                id: 104,
                fullName: "SchneeOrg/mobile-app",
                isPrivate: true,
                actionsAccess: .available
            ),
            GitHubRepositoryOptionModel(
                id: 105,
                fullName: "SchneeOrg/notification-hub",
                isPrivate: true,
                actionsAccess: .unverified
            ),
            GitHubRepositoryOptionModel(
                id: 106,
                fullName: "SchneeOrg/realtime",
                isPrivate: true,
                actionsAccess: .unverified
            ),
            GitHubRepositoryOptionModel(
                id: 107,
                fullName: "SchneeOrg/schneemail",
                isPrivate: true,
                actionsAccess: .available
            ),
            GitHubRepositoryOptionModel(
                id: 108,
                fullName: "SchneeOrg/software-distribution",
                isPrivate: false,
                actionsAccess: .available
            ),
            GitHubRepositoryOptionModel(
                id: 109,
                fullName: "SchneeOrg/web-console",
                isPrivate: true,
                actionsAccess: .available
            ),
            GitHubRepositoryOptionModel(
                id: 110,
                fullName: "SchneeOrg/worker-runtime",
                isPrivate: true,
                actionsAccess: .available
            ),
        ]
    )

    public static let selectedRepositoryIDs: Set<Int64> = [101, 102, 105, 107, 108]
}

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
            repository(101, "SchneeOrg/api-gateway", isPrivate: true, actions: .unavailable, reviews: .available, checks: .unverified, deployments: .unavailable),
            repository(102, "SchneeOrg/authentication-platform", isPrivate: true, actions: .available, reviews: .available, checks: .available, deployments: .available),
            repository(103, "SchneeOrg/design-system", isPrivate: false, actions: .unavailable, reviews: .unverified, checks: .unavailable, deployments: .unverified),
            repository(104, "SchneeOrg/mobile-app", isPrivate: true, actions: .available, reviews: .available, checks: .available, deployments: .available),
            repository(105, "SchneeOrg/notification-hub", isPrivate: true, actions: .unverified, reviews: .unavailable, checks: .available, deployments: .unverified),
            repository(106, "SchneeOrg/realtime", isPrivate: true, actions: .unverified, reviews: .available, checks: .unverified, deployments: .unavailable),
            repository(107, "SchneeOrg/schneemail", isPrivate: true, actions: .available, reviews: .available, checks: .available, deployments: .available),
            repository(108, "SchneeOrg/software-distribution", isPrivate: false, actions: .available, reviews: .unverified, checks: .available, deployments: .unverified),
            repository(109, "SchneeOrg/web-console", isPrivate: true, actions: .available, reviews: .available, checks: .unavailable, deployments: .unavailable),
            repository(110, "SchneeOrg/worker-runtime", isPrivate: true, actions: .available, reviews: .available, checks: .available, deployments: .available),
        ]
    )

    public static let mixedCapabilityModel = GitHubConnectionManagementModel(
        id: UUID(uuidString: "21000000-0000-0000-0000-000000000002")!,
        displayName: "Frost GitHub",
        host: "github.com",
        accountLogin: "snow-user",
        repositories: [
            repository(
                201,
                "snow-labs/frost",
                isPrivate: true,
                actions: .available,
                reviews: .unverified,
                checks: .unavailable,
                deployments: .available
            ),
            repository(
                202,
                "snow-labs/flurry",
                isPrivate: true,
                actions: .available,
                reviews: .available,
                checks: .available,
                deployments: .unverified
            ),
            repository(
                203,
                "snow-labs/glacier",
                isPrivate: true,
                actions: .unverified,
                reviews: .available,
                checks: .available,
                deployments: .unavailable
            ),
        ]
    )

    public static let selectedRepositoryIDs: Set<Int64> = [101, 102, 105, 107, 108]
    public static let mixedCapabilitySelectedRepositoryIDs: Set<Int64> = [201, 202, 203]

    private static func repository(
        _ id: Int64,
        _ fullName: String,
        isPrivate: Bool,
        actions: GitHubRepositoryActivityAccessPresentation,
        reviews: GitHubRepositoryActivityAccessPresentation,
        checks: GitHubRepositoryActivityAccessPresentation,
        deployments: GitHubRepositoryActivityAccessPresentation
    ) -> GitHubRepositoryOptionModel {
        GitHubRepositoryOptionModel(
            id: id,
            fullName: fullName,
            isPrivate: isPrivate,
            activityAccess: GitHubRepositoryActivityAccessModel(
                actions: actions,
                reviewRequests: reviews,
                checks: checks,
                deployments: deployments
            )
        )
    }
}

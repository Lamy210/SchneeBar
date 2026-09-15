import Foundation
import SchneeBarGitHub
import Testing

@Test
func hostedActionsReadPermissionIsAvailable() throws {
    let repository = try capabilityRepository(id: 1, isPrivate: true)
    let result = GitHubCapabilityEvaluator().evaluate(
        connection: try hostedCapabilityConnection(),
        inventory: capabilityInventory(
            repository: repository,
            permissions: ["actions": "read"]
        )
    )

    #expect(result.state(for: .actions, repositoryID: 1) == .available)
}

@Test
func hostedActionsWritePermissionAlsoSatisfiesReadCapability() throws {
    let repository = try capabilityRepository(id: 1, isPrivate: true)
    let result = GitHubCapabilityEvaluator().evaluate(
        connection: try hostedCapabilityConnection(),
        inventory: capabilityInventory(
            repository: repository,
            permissions: ["actions": "WRITE"]
        )
    )

    #expect(result.state(for: .actions, repositoryID: 1) == .available)
}

@Test
func privateRepositoryWithoutActionsPermissionIsUnavailable() throws {
    let repository = try capabilityRepository(id: 1, isPrivate: true)
    let result = GitHubCapabilityEvaluator().evaluate(
        connection: try hostedCapabilityConnection(),
        inventory: capabilityInventory(repository: repository, permissions: [:])
    )

    #expect(
        result.state(for: .actions, repositoryID: 1)
            == .unavailable(.missingPermission)
    )
}

@Test
func publicRepositoryWithoutActionsPermissionRemainsUnknown() throws {
    let repository = try capabilityRepository(id: 1, isPrivate: false)
    let result = GitHubCapabilityEvaluator().evaluate(
        connection: try hostedCapabilityConnection(),
        inventory: capabilityInventory(repository: repository, permissions: [:])
    )

    #expect(
        result.state(for: .actions, repositoryID: 1)
            == .unknown([.publicRepositoryPermissionNotProven])
    )
}

@Test
func unrecognizedPermissionLevelRemainsUnknown() throws {
    let repository = try capabilityRepository(id: 1, isPrivate: true)
    let result = GitHubCapabilityEvaluator().evaluate(
        connection: try hostedCapabilityConnection(),
        inventory: capabilityInventory(
            repository: repository,
            permissions: ["actions": "admin"]
        )
    )

    #expect(
        result.state(for: .actions, repositoryID: 1)
            == .unknown([.unrecognizedPermissionLevel])
    )
}

@Test
func readCapabilitiesUseTheirOwnPermissionKeys() throws {
    let repository = try capabilityRepository(id: 1, isPrivate: true)
    let result = GitHubCapabilityEvaluator().evaluate(
        connection: try hostedCapabilityConnection(),
        inventory: capabilityInventory(
            repository: repository,
            permissions: [
                "pull_requests": "read",
                "checks": "read",
                "deployments": "write",
            ]
        )
    )

    #expect(result.state(for: .pullRequests, repositoryID: 1) == .available)
    #expect(result.state(for: .checks, repositoryID: 1) == .available)
    #expect(result.state(for: .deployments, repositoryID: 1) == .available)
    #expect(result.state(for: .actions, repositoryID: 1) == .unavailable(.missingPermission))
}

@Test
func unmappedCapabilitiesRemainUnknown() throws {
    let repository = try capabilityRepository(id: 1, isPrivate: true)
    let result = GitHubCapabilityEvaluator().evaluate(
        connection: try hostedCapabilityConnection(),
        inventory: capabilityInventory(
            repository: repository,
            permissions: ["contents": "write"]
        )
    )

    for capability in [
        GitHubCapability.releases,
        .mergeQueue,
        .securityAlerts,
        .workflowWrite,
    ] {
        #expect(
            result.state(for: capability, repositoryID: 1)
                == .unknown([.unmappedCapability])
        )
    }
}

@Test
func testedEnterpriseWithPermissionIsAvailable() throws {
    let repository = try capabilityRepository(id: 1, isPrivate: true)
    let result = GitHubCapabilityEvaluator().evaluate(
        connection: try enterpriseCapabilityConnection(serverVersion: "3.22.0"),
        inventory: capabilityInventory(
            repository: repository,
            permissions: ["actions": "read"]
        )
    )

    #expect(result.state(for: .actions, repositoryID: 1) == .available)
}

@Test
func untestedEnterpriseWithPermissionIsUnknownRatherThanUnavailable() throws {
    let repository = try capabilityRepository(id: 1, isPrivate: true)
    let result = GitHubCapabilityEvaluator().evaluate(
        connection: try enterpriseCapabilityConnection(serverVersion: "3.23.0"),
        inventory: capabilityInventory(
            repository: repository,
            permissions: ["actions": "read"]
        )
    )

    #expect(
        result.state(for: .actions, repositoryID: 1)
            == .unknown([.untestedEnterpriseVersion])
    )
}

@Test
func unknownEnterpriseVersionWithPermissionRemainsUnknown() throws {
    let repository = try capabilityRepository(id: 1, isPrivate: true)
    let result = GitHubCapabilityEvaluator().evaluate(
        connection: try enterpriseCapabilityConnection(serverVersion: nil),
        inventory: capabilityInventory(
            repository: repository,
            permissions: ["actions": "read"]
        )
    )

    #expect(
        result.state(for: .actions, repositoryID: 1)
            == .unknown([.unknownEnterpriseVersion])
    )
}

@Test
func untestedEnterpriseAndPublicPermissionFallbackPreserveBothUncertainties() throws {
    let repository = try capabilityRepository(id: 1, isPrivate: false)
    let result = GitHubCapabilityEvaluator().evaluate(
        connection: try enterpriseCapabilityConnection(serverVersion: "3.23.0"),
        inventory: capabilityInventory(repository: repository, permissions: [:])
    )

    #expect(
        result.state(for: .actions, repositoryID: 1)
            == .unknown([
                .untestedEnterpriseVersion,
                .publicRepositoryPermissionNotProven,
            ])
    )
}

@Test
func duplicateIdenticalEvidenceCollapsesDeterministically() throws {
    let repository = try capabilityRepository(id: 9, isPrivate: true)
    let inventory = capabilityInventory(
        installations: [
            capabilityInstallationAccess(
                id: 10,
                repositories: [repository],
                permissions: ["actions": "read"]
            ),
            capabilityInstallationAccess(
                id: 20,
                repositories: [repository],
                permissions: ["actions": "read"]
            ),
        ]
    )

    let result = GitHubCapabilityEvaluator().evaluate(
        connection: try hostedCapabilityConnection(),
        inventory: inventory
    )

    #expect(result.repositories.count == 1)
    #expect(result.state(for: .actions, repositoryID: 9) == .available)
}

@Test
func duplicateConflictingEvidenceBecomesUnknown() throws {
    let repository = try capabilityRepository(id: 9, isPrivate: true)
    let inventory = capabilityInventory(
        installations: [
            capabilityInstallationAccess(
                id: 10,
                repositories: [repository],
                permissions: ["actions": "read"]
            ),
            capabilityInstallationAccess(
                id: 20,
                repositories: [repository],
                permissions: [:]
            ),
        ]
    )

    let result = GitHubCapabilityEvaluator().evaluate(
        connection: try hostedCapabilityConnection(),
        inventory: inventory
    )

    #expect(
        result.state(for: .actions, repositoryID: 9)
            == .unknown([.conflictingEvidence])
    )
}

@Test
func installationFailuresAreNormalizedWithoutInventingRepositoryAssociations() throws {
    let inventory = capabilityInventory(
        installations: [
            capabilityInstallationAccess(id: 4, status: .unavailable),
            capabilityInstallationAccess(id: 2, status: .forbidden),
            capabilityInstallationAccess(id: 1, status: .suspended),
            capabilityInstallationAccess(id: 3, status: .notFound),
        ]
    )

    let result = GitHubCapabilityEvaluator().evaluate(
        connection: try hostedCapabilityConnection(),
        inventory: inventory
    )

    #expect(result.repositories.isEmpty)
    #expect(
        result.installationIssues == [
            GitHubInstallationCapabilityIssue(installationID: 1, reason: .suspended),
            GitHubInstallationCapabilityIssue(installationID: 2, reason: .forbidden),
            GitHubInstallationCapabilityIssue(installationID: 3, reason: .notFound),
            GitHubInstallationCapabilityIssue(installationID: 4, reason: .unavailable),
        ]
    )
}

private func hostedCapabilityConnection() throws -> GitHubConnection {
    GitHubConnection(
        id: UUID(uuidString: "10000000-0000-0000-0000-000000000001")!,
        displayName: "Hosted GitHub",
        deploymentKind: .githubDotCom,
        webBaseURL: try #require(URL(string: "https://github.example.test"))
    )
}

private func enterpriseCapabilityConnection(
    serverVersion: String?
) throws -> GitHubConnection {
    GitHubConnection(
        id: UUID(uuidString: "10000000-0000-0000-0000-000000000002")!,
        displayName: "Enterprise GitHub",
        deploymentKind: .enterpriseServer,
        webBaseURL: try #require(URL(string: "https://enterprise.example.test")),
        serverVersion: serverVersion
    )
}

private func capabilityInventory(
    repository: GitHubRepositoryAccess,
    permissions: [String: String]
) -> GitHubAccessInventory {
    capabilityInventory(
        installations: [
            capabilityInstallationAccess(
                id: 1,
                repositories: [repository],
                permissions: permissions
            ),
        ]
    )
}

private func capabilityInventory(
    installations: [GitHubInstallationAccess]
) -> GitHubAccessInventory {
    GitHubAccessInventory(
        account: GitHubAuthenticatedAccount(
            identity: GitHubAccountIdentity(id: "100", login: "octocat")
        ),
        installations: installations
    )
}

private func capabilityInstallationAccess(
    id: Int64,
    repositories: [GitHubRepositoryAccess] = [],
    permissions: [String: String] = [:],
    status: GitHubInstallationAccessStatus = .available
) -> GitHubInstallationAccess {
    GitHubInstallationAccess(
        installation: GitHubInstallation(
            id: id,
            account: GitHubInstallationAccount(
                id: String(id),
                login: "example-org",
                type: "Organization"
            ),
            repositorySelection: "all",
            permissions: permissions,
            isSuspended: status == .suspended
        ),
        repositories: repositories,
        status: status
    )
}

private func capabilityRepository(
    id: Int64,
    isPrivate: Bool
) throws -> GitHubRepositoryAccess {
    GitHubRepositoryAccess(
        id: id,
        name: "service-\(id)",
        fullName: "example-org/service-\(id)",
        isPrivate: isPrivate,
        webURL: try #require(URL(string: "https://github.example.test/example-org/service-\(id)")),
        ownerLogin: "example-org",
        permissions: GitHubRepositoryPermissions(pull: true)
    )
}

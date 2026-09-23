import Foundation

public enum GitHubCapabilityBlocker: Equatable, Sendable {
    case missingPermission
    case insufficientRepositoryAccess
}

public enum GitHubCapabilityUncertainty: Hashable, Sendable {
    case publicRepositoryPermissionNotProven
    case untestedEnterpriseVersion
    case unknownEnterpriseVersion
    case unmappedCapability
    case unrecognizedPermissionLevel
    case conflictingEvidence
}

public enum GitHubCapabilityState: Equatable, Sendable {
    case available
    case unavailable(GitHubCapabilityBlocker)
    case unknown(Set<GitHubCapabilityUncertainty>)
}

public struct GitHubRepositoryCapabilityAssessment: Equatable, Sendable {
    public let repositoryID: Int64
    public let states: [GitHubCapability: GitHubCapabilityState]

    public init(
        repositoryID: Int64,
        states: [GitHubCapability: GitHubCapabilityState]
    ) {
        self.repositoryID = repositoryID
        self.states = states
    }
}

public enum GitHubInstallationCapabilityIssueReason: Equatable, Sendable {
    case suspended
    case ssoRequired
    case forbidden
    case notFound
    case unavailable
}

public struct GitHubInstallationCapabilityIssue: Equatable, Sendable {
    public let installationID: Int64
    public let reason: GitHubInstallationCapabilityIssueReason

    public init(
        installationID: Int64,
        reason: GitHubInstallationCapabilityIssueReason
    ) {
        self.installationID = installationID
        self.reason = reason
    }
}

public struct GitHubConnectionCapabilityAssessment: Equatable, Sendable {
    public let repositories: [Int64: GitHubRepositoryCapabilityAssessment]
    public let installationIssues: [GitHubInstallationCapabilityIssue]

    public init(
        repositories: [Int64: GitHubRepositoryCapabilityAssessment] = [:],
        installationIssues: [GitHubInstallationCapabilityIssue] = []
    ) {
        self.repositories = repositories
        self.installationIssues = installationIssues
    }

    public func state(
        for capability: GitHubCapability,
        repositoryID: Int64
    ) -> GitHubCapabilityState? {
        repositories[repositoryID]?.states[capability]
    }
}

public struct GitHubCapabilityEvaluator: Sendable {
    private enum RequiredPermissionLevel: Sendable {
        case read
        case write

        func isSatisfied(by level: String) -> Bool {
            switch (self, level) {
            case (.read, "read"), (.read, "write"), (.write, "write"):
                return true
            default:
                return false
            }
        }
    }

    private struct PermissionRequirement: Sendable {
        let key: String
        let level: RequiredPermissionLevel
        let allowsPublicReadFallback: Bool
    }

    private static let permissionRequirements: [
        GitHubCapability: PermissionRequirement
    ] = [
        .actions: PermissionRequirement(
            key: "actions",
            level: .read,
            allowsPublicReadFallback: true
        ),
        .pullRequests: PermissionRequirement(
            key: "pull_requests",
            level: .read,
            allowsPublicReadFallback: true
        ),
        .checks: PermissionRequirement(
            key: "checks",
            level: .read,
            allowsPublicReadFallback: true
        ),
        .deployments: PermissionRequirement(
            key: "deployments",
            level: .read,
            allowsPublicReadFallback: true
        ),
        .workflowWrite: PermissionRequirement(
            key: "actions",
            level: .write,
            allowsPublicReadFallback: false
        ),
    ]

    private let compatibilityPolicy: GitHubEnterpriseCompatibilityPolicy

    public init(
        compatibilityPolicy: GitHubEnterpriseCompatibilityPolicy = .init()
    ) {
        self.compatibilityPolicy = compatibilityPolicy
    }

    public func evaluate(
        connection: GitHubConnection,
        inventory: GitHubAccessInventory
    ) -> GitHubConnectionCapabilityAssessment {
        let platformUncertainties = platformUncertainties(for: connection)
        var repositories: [Int64: GitHubRepositoryCapabilityAssessment] = [:]
        var installationIssues: [GitHubInstallationCapabilityIssue] = []

        for installationAccess in inventory.installations {
            guard installationAccess.status == .available else {
                installationIssues.append(
                    GitHubInstallationCapabilityIssue(
                        installationID: installationAccess.installation.id,
                        reason: issueReason(for: installationAccess.status)
                    )
                )
                continue
            }

            for repository in installationAccess.repositories {
                let candidate = assess(
                    repository: repository,
                    permissions: installationAccess.installation.permissions,
                    platformUncertainties: platformUncertainties
                )

                if let existing = repositories[repository.id] {
                    repositories[repository.id] = merge(existing, candidate)
                } else {
                    repositories[repository.id] = candidate
                }
            }
        }

        installationIssues.sort(by: installationIssueSort)
        return GitHubConnectionCapabilityAssessment(
            repositories: repositories,
            installationIssues: installationIssues
        )
    }

    private func assess(
        repository: GitHubRepositoryAccess,
        permissions: [String: String],
        platformUncertainties: Set<GitHubCapabilityUncertainty>
    ) -> GitHubRepositoryCapabilityAssessment {
        let states = Dictionary(
            uniqueKeysWithValues: GitHubCapability.allCases.map { capability in
                (
                    capability,
                    state(
                        for: capability,
                        repository: repository,
                        permissions: permissions,
                        platformUncertainties: platformUncertainties
                    )
                )
            }
        )
        return GitHubRepositoryCapabilityAssessment(
            repositoryID: repository.id,
            states: states
        )
    }

    private func state(
        for capability: GitHubCapability,
        repository: GitHubRepositoryAccess,
        permissions: [String: String],
        platformUncertainties: Set<GitHubCapabilityUncertainty>
    ) -> GitHubCapabilityState {
        guard let requirement = Self.permissionRequirements[capability] else {
            var uncertainties = platformUncertainties
            uncertainties.insert(.unmappedCapability)
            return .unknown(uncertainties)
        }

        let rawLevel = permissions[requirement.key]
        let level = rawLevel?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()

        switch level {
        case "read", "write":
            guard let level,
                  requirement.level.isSatisfied(by: level)
            else {
                return .unavailable(.missingPermission)
            }
            if capability == .workflowWrite,
               !hasRepositoryWriteAccess(repository.permissions)
            {
                return .unavailable(.insufficientRepositoryAccess)
            }
            if platformUncertainties.isEmpty {
                return .available
            }
            return .unknown(platformUncertainties)

        case nil, "":
            if !repository.isPrivate,
               requirement.allowsPublicReadFallback
            {
                var uncertainties = platformUncertainties
                uncertainties.insert(.publicRepositoryPermissionNotProven)
                return .unknown(uncertainties)
            }
            return .unavailable(.missingPermission)

        default:
            var uncertainties = platformUncertainties
            uncertainties.insert(.unrecognizedPermissionLevel)
            return .unknown(uncertainties)
        }
    }

    private func hasRepositoryWriteAccess(
        _ permissions: GitHubRepositoryPermissions
    ) -> Bool {
        permissions.admin || permissions.maintain || permissions.push
    }

    private func platformUncertainties(
        for connection: GitHubConnection
    ) -> Set<GitHubCapabilityUncertainty> {
        switch connection.deploymentKind {
        case .githubDotCom, .gheDotCom:
            return []

        case .enterpriseServer:
            let version = connection.serverVersion.flatMap(
                GitHubEnterpriseServerVersion.init(parsing:)
            )
            switch compatibilityPolicy.compatibility(for: version) {
            case .tested:
                return []
            case .olderUntested, .newerUntested:
                return [.untestedEnterpriseVersion]
            case .unknownVersion:
                return [.unknownEnterpriseVersion]
            }
        }
    }

    private func merge(
        _ lhs: GitHubRepositoryCapabilityAssessment,
        _ rhs: GitHubRepositoryCapabilityAssessment
    ) -> GitHubRepositoryCapabilityAssessment {
        var states: [GitHubCapability: GitHubCapabilityState] = [:]
        for capability in GitHubCapability.allCases {
            switch (lhs.states[capability], rhs.states[capability]) {
            case let (lhsState?, rhsState?):
                states[capability] = merge(lhsState, rhsState)
            case let (lhsState?, nil):
                states[capability] = lhsState
            case let (nil, rhsState?):
                states[capability] = rhsState
            case (nil, nil):
                break
            }
        }
        return GitHubRepositoryCapabilityAssessment(
            repositoryID: lhs.repositoryID,
            states: states
        )
    }

    private func merge(
        _ lhs: GitHubCapabilityState,
        _ rhs: GitHubCapabilityState
    ) -> GitHubCapabilityState {
        guard lhs != rhs else { return lhs }

        var uncertainties: Set<GitHubCapabilityUncertainty> = [.conflictingEvidence]
        if case let .unknown(lhsUncertainties) = lhs {
            uncertainties.formUnion(lhsUncertainties)
        }
        if case let .unknown(rhsUncertainties) = rhs {
            uncertainties.formUnion(rhsUncertainties)
        }
        return .unknown(uncertainties)
    }

    private func issueReason(
        for status: GitHubInstallationAccessStatus
    ) -> GitHubInstallationCapabilityIssueReason {
        switch status {
        case .available:
            return .unavailable
        case .suspended:
            return .suspended
        case .ssoRequired:
            return .ssoRequired
        case .forbidden:
            return .forbidden
        case .notFound:
            return .notFound
        case .unavailable:
            return .unavailable
        }
    }

    private func installationIssueSort(
        lhs: GitHubInstallationCapabilityIssue,
        rhs: GitHubInstallationCapabilityIssue
    ) -> Bool {
        if lhs.installationID != rhs.installationID {
            return lhs.installationID < rhs.installationID
        }
        return issueRank(lhs.reason) < issueRank(rhs.reason)
    }

    private func issueRank(_ reason: GitHubInstallationCapabilityIssueReason) -> Int {
        switch reason {
        case .suspended: 0
        case .forbidden: 1
        case .notFound: 2
        case .unavailable: 3
        case .ssoRequired: 4
        }
    }
}

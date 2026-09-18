import Foundation

public struct GitHubDeploymentEvidence: Equatable, Sendable {
    public let deployment: GitHubDeployment
    public let latestStatus: GitHubDeploymentStatus?

    public init(
        deployment: GitHubDeployment,
        latestStatus: GitHubDeploymentStatus?
    ) {
        self.deployment = deployment
        self.latestStatus = latestStatus
    }
}

public struct GitHubDeploymentTimelineEvidence: Equatable, Sendable {
    public let exactSHA: String
    public let deployments: [GitHubDeploymentEvidence]

    public init(
        exactSHA: String,
        deployments: [GitHubDeploymentEvidence]
    ) {
        self.exactSHA = exactSHA
        self.deployments = deployments
    }
}

public protocol GitHubDeploymentTimelineLoading: Sendable {
    func deploymentEvidence(
        connection: GitHubConnection,
        identity: GitHubAccountIdentity,
        clientID: String?,
        repository: GitHubRepositoryAccess,
        exactSHA: String
    ) async throws -> GitHubDeploymentTimelineEvidence
}

public struct GitHubDeploymentTimelineService: GitHubDeploymentTimelineLoading, Sendable {
    private static let deploymentListLimit = 20
    private static let statusRequestLimit = 3

    private let sessionCoordinator: GitHubConnectionSessionCoordinator
    private let deploymentClient: GitHubDeploymentClient

    public init(
        sessionCoordinator: GitHubConnectionSessionCoordinator,
        deploymentClient: GitHubDeploymentClient = .init()
    ) {
        self.sessionCoordinator = sessionCoordinator
        self.deploymentClient = deploymentClient
    }

    public func deploymentEvidence(
        connection: GitHubConnection,
        identity: GitHubAccountIdentity,
        clientID: String?,
        repository: GitHubRepositoryAccess,
        exactSHA: String
    ) async throws -> GitHubDeploymentTimelineEvidence {
        let normalizedSHA = exactSHA
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()

        let credential = try await sessionCoordinator.authorizedCredential(
            connection: connection,
            identity: identity,
            clientID: clientID
        )

        try Task.checkCancellation()
        let deployments = try await deploymentClient.deployments(
            sha: normalizedSHA,
            repository: repository,
            connection: connection,
            credential: credential,
            limit: Self.deploymentListLimit
        )

        var evidence: [GitHubDeploymentEvidence] = []
        evidence.reserveCapacity(min(Self.statusRequestLimit, deployments.count))

        for deployment in orderedDeployments(deployments)
            .prefix(Self.statusRequestLimit)
        {
            try Task.checkCancellation()
            let latestStatus = try await deploymentClient.latestStatus(
                deploymentID: deployment.id,
                repository: repository,
                connection: connection,
                credential: credential
            )
            evidence.append(
                GitHubDeploymentEvidence(
                    deployment: deployment,
                    latestStatus: latestStatus
                )
            )
        }

        return GitHubDeploymentTimelineEvidence(
            exactSHA: normalizedSHA,
            deployments: evidence
        )
    }

    private func orderedDeployments(
        _ deployments: [GitHubDeployment]
    ) -> [GitHubDeployment] {
        deployments.sorted { lhs, rhs in
            if lhs.isProductionEnvironment != rhs.isProductionEnvironment {
                return lhs.isProductionEnvironment
            }

            if lhs.isTransientEnvironment != rhs.isTransientEnvironment {
                return !lhs.isTransientEnvironment
            }

            if lhs.updatedAt != rhs.updatedAt {
                return dateDesc(lhs.updatedAt, rhs.updatedAt)
            }

            if lhs.createdAt != rhs.createdAt {
                return dateDesc(lhs.createdAt, rhs.createdAt)
            }

            return lhs.id > rhs.id
        }
    }

    private func dateDesc(_ lhs: Date?, _ rhs: Date?) -> Bool {
        switch (lhs, rhs) {
        case let (lhs?, rhs?):
            return lhs > rhs
        case (_?, nil):
            return true
        case (nil, _?):
            return false
        case (nil, nil):
            return false
        }
    }
}

import Foundation

public struct GitHubDeliveryTimelineEvidence: Equatable, Sendable {
    public let selectedRun: GitHubWorkflowRun
    public let pullRequest: GitHubPullRequestMetadata?
    public let baseRuns: [GitHubWorkflowRun]
    public let associatedPullRequestNumbersByRunID: [Int64: [Int]]
    public let repositoryDefaultBranch: String?

    public init(
        selectedRun: GitHubWorkflowRun,
        pullRequest: GitHubPullRequestMetadata?,
        baseRuns: [GitHubWorkflowRun],
        associatedPullRequestNumbersByRunID: [Int64: [Int]],
        repositoryDefaultBranch: String? = nil
    ) {
        self.selectedRun = selectedRun
        self.pullRequest = pullRequest
        self.baseRuns = baseRuns
        self.associatedPullRequestNumbersByRunID = associatedPullRequestNumbersByRunID
        self.repositoryDefaultBranch = repositoryDefaultBranch
    }
}

public protocol GitHubDeliveryTimelineLoading: Sendable {
    func timelineEvidence(
        connection: GitHubConnection,
        identity: GitHubAccountIdentity,
        clientID: String?,
        repository: GitHubRepositoryAccess,
        runID: Int64
    ) async throws -> GitHubDeliveryTimelineEvidence
}

public struct GitHubDeliveryTimelineService: GitHubDeliveryTimelineLoading, Sendable {
    private static let baseRunLimit = 20
    private static let associationRequestLimit = 4

    private let sessionCoordinator: GitHubConnectionSessionCoordinator
    private let actionsClient: GitHubActionsClient
    private let pullRequestClient: GitHubPullRequestMetadataClient
    private let commitPullRequestClient: GitHubCommitPullRequestClient

    public init(
        sessionCoordinator: GitHubConnectionSessionCoordinator,
        actionsClient: GitHubActionsClient = .init(),
        pullRequestClient: GitHubPullRequestMetadataClient = .init(),
        commitPullRequestClient: GitHubCommitPullRequestClient = .init()
    ) {
        self.sessionCoordinator = sessionCoordinator
        self.actionsClient = actionsClient
        self.pullRequestClient = pullRequestClient
        self.commitPullRequestClient = commitPullRequestClient
    }

    public func timelineEvidence(
        connection: GitHubConnection,
        identity: GitHubAccountIdentity,
        clientID: String?,
        repository: GitHubRepositoryAccess,
        runID: Int64
    ) async throws -> GitHubDeliveryTimelineEvidence {
        let credential = try await sessionCoordinator.authorizedCredential(
            connection: connection,
            identity: identity,
            clientID: clientID
        )

        try Task.checkCancellation()
        let selectedRun = try await actionsClient.workflowRun(
            id: runID,
            repository: repository,
            connection: connection,
            credential: credential
        )

        let pullRequestNumbers = Set(selectedRun.pullRequestNumbers.filter { $0 > 0 })
        guard pullRequestNumbers.count == 1,
              let pullRequestNumber = pullRequestNumbers.first
        else {
            return emptyEvidence(
                selectedRun: selectedRun,
                repositoryDefaultBranch: repository.defaultBranch
            )
        }

        try Task.checkCancellation()
        let pullRequest = try await pullRequestClient.pullRequest(
            number: pullRequestNumber,
            repository: repository,
            connection: connection,
            credential: credential
        )

        guard pullRequest.isMerged, pullRequest.mergedAt != nil else {
            return GitHubDeliveryTimelineEvidence(
                selectedRun: selectedRun,
                pullRequest: pullRequest,
                baseRuns: [],
                associatedPullRequestNumbersByRunID: [:],
                repositoryDefaultBranch: repository.defaultBranch
            )
        }

        try Task.checkCancellation()
        let loadedBaseRuns = try await actionsClient.workflowRuns(
            repository: repository,
            connection: connection,
            credential: credential,
            query: GitHubWorkflowRunQuery(
                branch: pullRequest.baseRef,
                limit: Self.baseRunLimit
            )
        )
        let candidates = orderedCandidates(
            loadedBaseRuns,
            selectedRun: selectedRun,
            baseRef: pullRequest.baseRef
        )

        var associationRequestCount = 0
        var associationsBySHA: [String: [Int]] = [:]
        var associationsByRunID: [Int64: [Int]] = [:]

        for candidate in candidates {
            try Task.checkCancellation()
            let sha = normalizedSHA(candidate.headSHA)

            let associatedNumbers: [Int]
            if let cached = associationsBySHA[sha] {
                associatedNumbers = cached
            } else {
                guard associationRequestCount < Self.associationRequestLimit else {
                    break
                }

                associatedNumbers = try await commitPullRequestClient.firstPagePullRequestNumbers(
                    for: candidate.headSHA,
                    repository: repository,
                    connection: connection,
                    credential: credential
                )
                associationRequestCount += 1
                associationsBySHA[sha] = associatedNumbers
            }

            associationsByRunID[candidate.id] = associatedNumbers
            if associatedNumbers.contains(pullRequestNumber) {
                break
            }
        }

        return GitHubDeliveryTimelineEvidence(
            selectedRun: selectedRun,
            pullRequest: pullRequest,
            baseRuns: candidates,
            associatedPullRequestNumbersByRunID: associationsByRunID,
            repositoryDefaultBranch: repository.defaultBranch
        )
    }

    private func emptyEvidence(
        selectedRun: GitHubWorkflowRun,
        repositoryDefaultBranch: String?
    ) -> GitHubDeliveryTimelineEvidence {
        GitHubDeliveryTimelineEvidence(
            selectedRun: selectedRun,
            pullRequest: nil,
            baseRuns: [],
            associatedPullRequestNumbersByRunID: [:],
            repositoryDefaultBranch: repositoryDefaultBranch
        )
    }

    private func orderedCandidates(
        _ runs: [GitHubWorkflowRun],
        selectedRun: GitHubWorkflowRun,
        baseRef: String
    ) -> [GitHubWorkflowRun] {
        let normalizedBaseRef = baseRef.trimmingCharacters(in: .whitespacesAndNewlines)

        return runs
            .filter { run in
                guard run.id != selectedRun.id,
                      run.headBranch?.trimmingCharacters(in: .whitespacesAndNewlines) == normalizedBaseRef,
                      !normalizedSHA(run.headSHA).isEmpty
                else {
                    return false
                }
                return true
            }
            .sorted { lhs, rhs in
                let lhsSameWorkflow = lhs.workflowID == selectedRun.workflowID
                let rhsSameWorkflow = rhs.workflowID == selectedRun.workflowID
                if lhsSameWorkflow != rhsSameWorkflow {
                    return lhsSameWorkflow
                }
                if lhs.updatedAt != rhs.updatedAt {
                    return lhs.updatedAt > rhs.updatedAt
                }
                return lhs.id > rhs.id
            }
    }

    private func normalizedSHA(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }
}

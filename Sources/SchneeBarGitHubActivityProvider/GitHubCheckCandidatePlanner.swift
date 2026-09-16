import SchneeBarGitHub

struct GitHubCheckCandidate: Equatable, Sendable {
    let repositoryID: Int64
    let headSHA: String
}

struct GitHubCheckCandidatePlanner: Sendable {
    func candidates(
        repositories: [GitHubRepositoryAccess],
        reviewRequestsByRepositoryID: [Int64: [GitHubReviewRequest]],
        workflowEvidenceByRepositoryID: [Int64: [GitHubWorkflowEvidence]],
        maximumTotal: Int,
        maximumPerRepository: Int
    ) -> [GitHubCheckCandidate] {
        guard maximumTotal > 0, maximumPerRepository > 0 else { return [] }

        var result: [GitHubCheckCandidate] = []
        result.reserveCapacity(maximumTotal)

        for repository in repositories.sorted(by: repositorySort) {
            guard result.count < maximumTotal else { break }

            var seenSHAs = Set<String>()
            var repositoryCandidates: [GitHubCheckCandidate] = []

            let reviews = reviewRequestsByRepositoryID[repository.id, default: []]
                .sorted(by: reviewSort)
            for review in reviews {
                guard seenSHAs.insert(review.headSHA).inserted else { continue }
                repositoryCandidates.append(
                    GitHubCheckCandidate(
                        repositoryID: repository.id,
                        headSHA: review.headSHA
                    )
                )
                if repositoryCandidates.count == maximumPerRepository {
                    break
                }
            }

            if repositoryCandidates.count < maximumPerRepository {
                let evidence = workflowEvidenceByRepositoryID[repository.id, default: []]
                    .sorted(by: workflowSort)
                for item in evidence {
                    guard seenSHAs.insert(item.headSHA).inserted else { continue }
                    repositoryCandidates.append(
                        GitHubCheckCandidate(
                            repositoryID: repository.id,
                            headSHA: item.headSHA
                        )
                    )
                    if repositoryCandidates.count == maximumPerRepository {
                        break
                    }
                }
            }

            result.append(
                contentsOf: repositoryCandidates.prefix(maximumTotal - result.count)
            )
        }

        return result
    }

    private func repositorySort(
        lhs: GitHubRepositoryAccess,
        rhs: GitHubRepositoryAccess
    ) -> Bool {
        if lhs.fullName != rhs.fullName {
            return lhs.fullName < rhs.fullName
        }
        return lhs.id < rhs.id
    }

    private func reviewSort(
        lhs: GitHubReviewRequest,
        rhs: GitHubReviewRequest
    ) -> Bool {
        if lhs.updatedAt != rhs.updatedAt {
            return lhs.updatedAt > rhs.updatedAt
        }
        return lhs.number < rhs.number
    }

    private func workflowSort(
        lhs: GitHubWorkflowEvidence,
        rhs: GitHubWorkflowEvidence
    ) -> Bool {
        let lhsRank = workflowRank(lhs.classification)
        let rhsRank = workflowRank(rhs.classification)
        if lhsRank != rhsRank {
            return lhsRank < rhsRank
        }
        if lhs.updatedAt != rhs.updatedAt {
            return lhs.updatedAt > rhs.updatedAt
        }
        return lhs.headSHA < rhs.headSHA
    }

    private func workflowRank(
        _ classification: GitHubWorkflowActivityClassification
    ) -> Int {
        switch classification {
        case .failed: 0
        case .running: 1
        case .waiting: 2
        case .success: 3
        case .ignored: 4
        }
    }
}

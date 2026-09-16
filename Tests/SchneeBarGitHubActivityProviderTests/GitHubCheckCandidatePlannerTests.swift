import Foundation
import SchneeBarGitHub
@testable import SchneeBarGitHubActivityProvider
import Testing

@Test
func reviewCandidatesPrecedeWorkflowEvidenceAndDeduplicateSHAs() throws {
    let planner = GitHubCheckCandidatePlanner()
    let repositories = [try candidateRepository(id: 1, name: "alpha")]
    let sharedSHA = String(repeating: "a", count: 40)
    let successSHA = String(repeating: "b", count: 40)

    let candidates = planner.candidates(
        repositories: repositories,
        reviewRequestsByRepositoryID: [
            1: [try candidateReview(number: 10, sha: sharedSHA, updatedAt: 300)],
        ],
        workflowEvidenceByRepositoryID: [
            1: [
                GitHubWorkflowEvidence(
                    repositoryID: 1,
                    headSHA: sharedSHA,
                    classification: .failed,
                    updatedAt: Date(timeIntervalSince1970: 250),
                    isVisible: true
                ),
                GitHubWorkflowEvidence(
                    repositoryID: 1,
                    headSHA: successSHA,
                    classification: .success,
                    updatedAt: Date(timeIntervalSince1970: 200),
                    isVisible: false
                ),
            ],
        ],
        maximumTotal: 4,
        maximumPerRepository: 2
    )

    #expect(candidates.map(\.headSHA) == [sharedSHA, successSHA])
}

@Test
func hiddenSuccessfulWorkflowStillSeedsCheckDiscovery() throws {
    let planner = GitHubCheckCandidatePlanner()
    let successSHA = String(repeating: "c", count: 40)

    let candidates = planner.candidates(
        repositories: [try candidateRepository(id: 1, name: "alpha")],
        reviewRequestsByRepositoryID: [:],
        workflowEvidenceByRepositoryID: [
            1: [
                GitHubWorkflowEvidence(
                    repositoryID: 1,
                    headSHA: successSHA,
                    classification: .success,
                    updatedAt: Date(timeIntervalSince1970: 100),
                    isVisible: false
                ),
            ],
        ],
        maximumTotal: 4,
        maximumPerRepository: 2
    )

    #expect(candidates == [GitHubCheckCandidate(repositoryID: 1, headSHA: successSHA)])
}

@Test
func plannerEnforcesPerRepositoryAndGlobalBoundsDeterministically() throws {
    let planner = GitHubCheckCandidatePlanner()
    let repositories = [
        try candidateRepository(id: 1, name: "alpha"),
        try candidateRepository(id: 2, name: "beta"),
        try candidateRepository(id: 3, name: "gamma"),
    ]

    let candidates = planner.candidates(
        repositories: repositories,
        reviewRequestsByRepositoryID: [
            1: [
                try candidateReview(number: 1, sha: String(repeating: "1", count: 40), updatedAt: 300),
                try candidateReview(number: 2, sha: String(repeating: "2", count: 40), updatedAt: 200),
                try candidateReview(number: 3, sha: String(repeating: "3", count: 40), updatedAt: 100),
            ],
            2: [
                try candidateReview(number: 4, sha: String(repeating: "4", count: 40), updatedAt: 300),
                try candidateReview(number: 5, sha: String(repeating: "5", count: 40), updatedAt: 200),
            ],
            3: [
                try candidateReview(number: 6, sha: String(repeating: "6", count: 40), updatedAt: 300),
            ],
        ],
        workflowEvidenceByRepositoryID: [:],
        maximumTotal: 4,
        maximumPerRepository: 2
    )

    #expect(candidates.map(\.repositoryID) == [1, 1, 2, 2])
}

private func candidateRepository(id: Int64, name: String) throws -> GitHubRepositoryAccess {
    GitHubRepositoryAccess(
        id: id,
        name: name,
        fullName: "snow-labs/\(name)",
        isPrivate: false,
        webURL: try #require(URL(string: "https://github.com/snow-labs/\(name)")),
        ownerLogin: "snow-labs",
        permissions: GitHubRepositoryPermissions(pull: true)
    )
}

private func candidateReview(number: Int, sha: String, updatedAt: TimeInterval) throws -> GitHubReviewRequest {
    GitHubReviewRequest(
        number: number,
        title: "Review \(number)",
        headSHA: sha,
        isDraft: false,
        updatedAt: Date(timeIntervalSince1970: updatedAt),
        requestedReviewerIDs: ["42"],
        webURL: try #require(URL(string: "https://github.com/snow-labs/alpha/pull/\(number)"))
    )
}

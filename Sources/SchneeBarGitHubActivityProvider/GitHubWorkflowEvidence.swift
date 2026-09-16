import Foundation
import SchneeBarGitHub

struct GitHubWorkflowEvidence: Equatable, Sendable {
    let repositoryID: Int64
    let headSHA: String
    let classification: GitHubWorkflowActivityClassification
    let updatedAt: Date
    let isVisible: Bool
}

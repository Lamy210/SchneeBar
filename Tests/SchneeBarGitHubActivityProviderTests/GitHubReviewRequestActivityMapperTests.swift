import Foundation
import SchneeBarCore
import SchneeBarGitHub
import SchneeBarGitHubActivityProvider
import Testing

@Test
func emitsOnlyDirectRequestsContainingConnectedStableAccountID() throws {
    let mapper = GitHubReviewRequestActivityMapper()
    let identity = GitHubAccountIdentity(id: "42", login: "renamed-user")
    let requests = [
        try reviewRequest(number: 7, reviewerIDs: ["42"], updatedAt: 300),
        try reviewRequest(number: 8, reviewerIDs: ["99"], updatedAt: 400),
        try reviewRequest(number: 9, reviewerIDs: [], updatedAt: 500),
    ]

    let visible = mapper.visibleRequests(requests: requests, identity: identity)

    #expect(visible.map(\.number) == [7])
}

@Test
func stableIDMatchSurvivesLoginRenameAndSortsNewestFirst() throws {
    let mapper = GitHubReviewRequestActivityMapper()
    let identity = GitHubAccountIdentity(id: "42", login: "new-login")
    let requests = [
        try reviewRequest(number: 7, reviewerIDs: ["42"], updatedAt: 100),
        try reviewRequest(number: 8, reviewerIDs: ["42", "99"], updatedAt: 200),
    ]

    let visible = mapper.visibleRequests(requests: requests, identity: identity)

    #expect(visible.map(\.number) == [8, 7])
}

@Test
func mapsReviewRequestToActionRequiredActivity() throws {
    let mapper = GitHubReviewRequestActivityMapper()
    let repository = try reviewMapperRepository()
    let request = try reviewRequest(
        number: 7,
        title: "Harden wake recovery",
        reviewerIDs: ["42"],
        updatedAt: 300
    )

    let item = mapper.activityItem(request: request, repository: repository)

    #expect(item.id == "github-review:42:7")
    #expect(item.repository == "snow-labs/frost")
    #expect(item.kind == .reviewRequest)
    #expect(item.attention == .actionRequired)
    #expect(item.state == .waiting)
    #expect(item.context == "PR #7")
    #expect(item.detail == "Review requested · Harden wake recovery")
    #expect(item.updatedAt == request.updatedAt)
    #expect(item.destinationURL == request.webURL)
}

private func reviewRequest(
    number: Int,
    title: String = "Review me",
    reviewerIDs: Set<String>,
    updatedAt: TimeInterval
) throws -> GitHubReviewRequest {
    GitHubReviewRequest(
        number: number,
        title: title,
        headSHA: String(repeating: String(number % 10), count: 40),
        isDraft: false,
        updatedAt: Date(timeIntervalSince1970: updatedAt),
        requestedReviewerIDs: reviewerIDs,
        webURL: try #require(URL(string: "https://github.com/snow-labs/frost/pull/\(number)"))
    )
}

private func reviewMapperRepository() throws -> GitHubRepositoryAccess {
    GitHubRepositoryAccess(
        id: 42,
        name: "frost",
        fullName: "snow-labs/frost",
        isPrivate: false,
        webURL: try #require(URL(string: "https://github.com/snow-labs/frost")),
        ownerLogin: "snow-labs",
        permissions: GitHubRepositoryPermissions(pull: true)
    )
}

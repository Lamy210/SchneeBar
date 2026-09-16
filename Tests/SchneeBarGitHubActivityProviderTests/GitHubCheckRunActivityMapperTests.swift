import Foundation
import SchneeBarCore
import SchneeBarGitHub
import SchneeBarGitHubActivityProvider
import Testing

@Test
func mapsFailedAndActiveChecksIntoTopLevelActivity() throws {
    let mapper = GitHubCheckRunActivityMapper()
    let repository = try checkMapperRepository()
    let sha = String(repeating: "a", count: 40)
    let checks = [
        try checkRun(id: 1, name: "Codecov", status: .completed, conclusion: .failure, appSlug: "codecov", sha: sha, startedAt: 100, completedAt: 200),
        try checkRun(id: 2, name: "Lint", status: .inProgress, conclusion: nil, appSlug: "third-party", sha: sha, startedAt: 150, completedAt: nil),
        try checkRun(id: 3, name: "Queued", status: .queued, conclusion: nil, appSlug: "third-party", sha: sha, startedAt: 120, completedAt: nil),
        try checkRun(id: 4, name: "Success", status: .completed, conclusion: .success, appSlug: "third-party", sha: sha, startedAt: 80, completedAt: 90),
    ]

    let items = mapper.visibleActivities(
        checks: checks,
        repository: repository,
        visibleWorkflowSHAs: []
    )

    #expect(items.map(\.id) == ["github-check:42:1", "github-check:42:2", "github-check:42:3"])
    #expect(items[0].kind == .checkRun)
    #expect(items[0].state == .failed)
    #expect(items[0].attention == .needsAttention)
    #expect(items[0].updatedAt == Date(timeIntervalSince1970: 200))
    #expect(items[1].state == .running)
    #expect(items[1].attention == .active)
    #expect(items[2].state == .waiting)
    #expect(items[2].attention == .active)
}

@Test
func suppressesOnlySameSHAGitHubActionsCheckWhenWorkflowIsVisible() throws {
    let mapper = GitHubCheckRunActivityMapper()
    let repository = try checkMapperRepository()
    let visibleSHA = String(repeating: "b", count: 40)
    let otherSHA = String(repeating: "c", count: 40)
    let checks = [
        try checkRun(id: 10, name: "Actions same", status: .completed, conclusion: .failure, appSlug: "github-actions", sha: visibleSHA, startedAt: 100, completedAt: 110),
        try checkRun(id: 11, name: "Actions other", status: .completed, conclusion: .failure, appSlug: "github-actions", sha: otherSHA, startedAt: 100, completedAt: 120),
        try checkRun(id: 12, name: "Codecov same", status: .completed, conclusion: .failure, appSlug: "codecov", sha: visibleSHA, startedAt: 100, completedAt: 130),
    ]

    let items = mapper.visibleActivities(
        checks: checks,
        repository: repository,
        visibleWorkflowSHAs: [visibleSHA]
    )

    #expect(Set(items.map(\.id)) == ["github-check:42:11", "github-check:42:12"])
}

@Test
func keepsGitHubActionsFailureWhenSameSHAWorkflowIsHidden() throws {
    let mapper = GitHubCheckRunActivityMapper()
    let repository = try checkMapperRepository()
    let sha = String(repeating: "d", count: 40)
    let checks = [
        try checkRun(id: 20, name: "Actions fallback", status: .completed, conclusion: .failure, appSlug: "github-actions", sha: sha, startedAt: 100, completedAt: 110),
    ]

    let items = mapper.visibleActivities(
        checks: checks,
        repository: repository,
        visibleWorkflowSHAs: []
    )

    #expect(items.map(\.id) == ["github-check:42:20"])
}

private func checkRun(
    id: Int64,
    name: String,
    status: GitHubCheckRunStatus,
    conclusion: GitHubCheckRunConclusion?,
    appSlug: String?,
    sha: String,
    startedAt: TimeInterval?,
    completedAt: TimeInterval?
) throws -> GitHubCheckRun {
    GitHubCheckRun(
        id: id,
        name: name,
        status: status,
        conclusion: conclusion,
        appSlug: appSlug,
        headSHA: sha,
        startedAt: startedAt.map(Date.init(timeIntervalSince1970:)),
        completedAt: completedAt.map(Date.init(timeIntervalSince1970:)),
        webURL: try #require(URL(string: "https://github.com/snow-labs/frost/commit/\(sha)/checks"))
    )
}

private func checkMapperRepository() throws -> GitHubRepositoryAccess {
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

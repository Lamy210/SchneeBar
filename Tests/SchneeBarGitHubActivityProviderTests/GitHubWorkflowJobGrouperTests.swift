import Foundation
import SchneeBarGitHub
import SchneeBarGitHubActivityProvider
import Testing

@Test
func grouperGroupsDistinctSameRunVariants() throws {
    let jobs = [
        grouperJob(id: 1, runID: 501, name: "Test (macos)"),
        grouperJob(id: 2, runID: 501, name: "Test (linux)"),
    ]

    let entries = GitHubWorkflowJobGrouper().entries(jobs: jobs)
    #expect(entries.count == 1)

    guard case let .variantGroup(group) = try #require(entries.first) else {
        Issue.record("Expected a variant group")
        return
    }
    #expect(group.runID == 501)
    #expect(group.baseName == "Test")
    #expect(group.variants.map(\.label) == ["linux", "macos"])
    #expect(group.variants.map(\.job.id) == [2, 1])
}

@Test
func grouperGroupsThreeSameBaseVariants() throws {
    let entries = GitHubWorkflowJobGrouper().entries(jobs: [
        grouperJob(id: 1, runID: 501, name: "Test (windows)"),
        grouperJob(id: 2, runID: 501, name: "Test (macos)"),
        grouperJob(id: 3, runID: 501, name: "Test (linux)"),
    ])

    guard case let .variantGroup(group) = try #require(entries.first) else {
        Issue.record("Expected a variant group")
        return
    }
    #expect(group.variants.map(\.label) == ["linux", "macos", "windows"])
}

@Test
func grouperRequiresAtLeastTwoVariants() {
    let job = grouperJob(id: 1, runID: 501, name: "Build (release)")
    let entries = GitHubWorkflowJobGrouper().entries(jobs: [job])

    #expect(entries == [.job(job)])
}

@Test
func grouperRejectsDuplicateVariantLabels() {
    let first = grouperJob(id: 1, runID: 501, name: "Test (macos)")
    let second = grouperJob(id: 2, runID: 501, name: "Test (macos)")
    let entries = GitHubWorkflowJobGrouper().entries(jobs: [second, first])

    #expect(entries == [.job(first), .job(second)])
}

@Test
func grouperDoesNotMixRunIDs() {
    let first = grouperJob(id: 1, runID: 501, name: "Test (macos)")
    let second = grouperJob(id: 2, runID: 502, name: "Test (linux)")
    let entries = GitHubWorkflowJobGrouper().entries(jobs: [second, first])

    #expect(entries == [.job(first), .job(second)])
}

@Test
func grouperKeepsDifferentBasesSeparate() {
    let testMac = grouperJob(id: 1, runID: 501, name: "Test (macos)")
    let testLinux = grouperJob(id: 2, runID: 501, name: "Test (linux)")
    let buildDebug = grouperJob(id: 3, runID: 501, name: "Build (debug)")
    let buildRelease = grouperJob(id: 4, runID: 501, name: "Build (release)")

    let entries = GitHubWorkflowJobGrouper().entries(jobs: [testLinux, buildRelease, testMac, buildDebug])

    #expect(entries.count == 2)
    guard case let .variantGroup(first) = entries[0],
          case let .variantGroup(second) = entries[1]
    else {
        Issue.record("Expected two variant groups")
        return
    }
    #expect(first.baseName == "Build")
    #expect(second.baseName == "Test")
}

@Test
func grouperRejectsNonTerminalSuffix() {
    let retry = grouperJob(id: 1, runID: 501, name: "Test (macos) retry")
    let linux = grouperJob(id: 2, runID: 501, name: "Test (linux)")

    let entries = GitHubWorkflowJobGrouper().entries(jobs: [linux, retry])
    #expect(entries == [.job(retry), .job(linux)])
}

@Test
func grouperRejectsEmptyBaseOrVariant() {
    let emptyBase = grouperJob(id: 1, runID: 501, name: "(macos)")
    let emptyVariant = grouperJob(id: 2, runID: 501, name: "Test ()")

    let entries = GitHubWorkflowJobGrouper().entries(jobs: [emptyVariant, emptyBase])
    #expect(entries == [.job(emptyBase), .job(emptyVariant)])
}

@Test
func grouperKeepsNestedSuffixOpaque() throws {
    let arm = grouperJob(id: 1, runID: 501, name: "Test (macos (arm64))")
    let intel = grouperJob(id: 2, runID: 501, name: "Test (macos (x86_64))")

    let entries = GitHubWorkflowJobGrouper().entries(jobs: [intel, arm])
    guard case let .variantGroup(group) = try #require(entries.first) else {
        Issue.record("Expected a variant group")
        return
    }
    #expect(group.variants.map(\.label) == ["macos (arm64)", "macos (x86_64)"])
}

@Test
func grouperRejectsUnbalancedSuffix() {
    let malformed = grouperJob(id: 1, runID: 501, name: "Test (macos (arm64)")
    let linux = grouperJob(id: 2, runID: 501, name: "Test (linux)")

    let entries = GitHubWorkflowJobGrouper().entries(jobs: [linux, malformed])
    #expect(entries == [.job(malformed), .job(linux)])
}

@Test
func grouperOrdersEntriesDeterministically() {
    let docs = grouperJob(id: 9, runID: 501, name: "Docs")
    let buildRelease = grouperJob(id: 4, runID: 501, name: "Build (release)")
    let testLinux = grouperJob(id: 2, runID: 501, name: "Test (linux)")
    let buildDebug = grouperJob(id: 3, runID: 501, name: "Build (debug)")
    let testMac = grouperJob(id: 1, runID: 501, name: "Test (macos)")

    let entries = GitHubWorkflowJobGrouper().entries(
        jobs: [testLinux, docs, buildRelease, testMac, buildDebug]
    )

    #expect(entries.map(grouperEntryName) == ["Build", "Docs", "Test"])
}

private func grouperEntryName(_ entry: GitHubWorkflowJobPresentationEntry) -> String {
    switch entry {
    case let .job(job): job.name
    case let .variantGroup(group): group.baseName
    }
}

private func grouperJob(
    id: Int64,
    runID: Int64,
    name: String
) -> GitHubWorkflowJob {
    GitHubWorkflowJob(
        id: id,
        runID: runID,
        name: name,
        status: .completed,
        conclusion: .success,
        startedAt: nil,
        completedAt: nil,
        webURL: URL(string: "https://github.com/octocat/project/actions/runs/\(runID)/job/\(id)")!,
        runnerName: nil,
        runnerGroupName: nil,
        labels: [],
        steps: []
    )
}

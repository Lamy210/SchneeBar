import SchneeBarGitHub
import Testing

@Test
func actionsAccessSummaryMapsAvailableUnknownAndUnavailableStates() {
    let assessment = GitHubConnectionCapabilityAssessment(
        repositories: [
            1: GitHubRepositoryCapabilityAssessment(
                repositoryID: 1,
                states: [.actions: .available]
            ),
            2: GitHubRepositoryCapabilityAssessment(
                repositoryID: 2,
                states: [.actions: .unknown([.publicRepositoryPermissionNotProven])]
            ),
            3: GitHubRepositoryCapabilityAssessment(
                repositoryID: 3,
                states: [.actions: .unavailable(.missingPermission)]
            ),
        ]
    )

    let summary = GitHubActionsAccessSummary.evaluate(
        repositoryIDs: [1, 2, 3],
        assessment: assessment
    )

    #expect(summary.accessByRepositoryID[1] == .available)
    #expect(summary.accessByRepositoryID[2] == .unverified)
    #expect(summary.accessByRepositoryID[3] == .unavailable)
    #expect(summary.unverifiedRepositoryCount == 1)
    #expect(summary.unavailableRepositoryCount == 1)
}

@Test
func actionsAccessSummaryTreatsMissingEvidenceAsUnverified() {
    let summary = GitHubActionsAccessSummary.evaluate(
        repositoryIDs: [42],
        assessment: nil
    )

    #expect(summary.accessByRepositoryID[42] == .unverified)
    #expect(summary.unverifiedRepositoryCount == 1)
    #expect(summary.unavailableRepositoryCount == 0)
}

@Test
func actionsAccessSummaryCountsOnlyRepositoriesInCurrentScope() {
    let assessment = GitHubConnectionCapabilityAssessment(
        repositories: [
            1: GitHubRepositoryCapabilityAssessment(
                repositoryID: 1,
                states: [.actions: .unavailable(.missingPermission)]
            ),
            2: GitHubRepositoryCapabilityAssessment(
                repositoryID: 2,
                states: [.actions: .unknown([.publicRepositoryPermissionNotProven])]
            ),
            3: GitHubRepositoryCapabilityAssessment(
                repositoryID: 3,
                states: [.actions: .available]
            ),
        ]
    )

    let summary = GitHubActionsAccessSummary.evaluate(
        repositoryIDs: [2, 3],
        assessment: assessment
    )

    #expect(summary.accessByRepositoryID[1] == nil)
    #expect(summary.accessByRepositoryID[2] == .unverified)
    #expect(summary.accessByRepositoryID[3] == .available)
    #expect(summary.unverifiedRepositoryCount == 1)
    #expect(summary.unavailableRepositoryCount == 0)
}

@Test
func actionsAccessSummaryHasNoWarningsWhenAllScopedRepositoriesAreAvailable() {
    let assessment = GitHubConnectionCapabilityAssessment(
        repositories: [
            1: GitHubRepositoryCapabilityAssessment(
                repositoryID: 1,
                states: [.actions: .available]
            ),
            2: GitHubRepositoryCapabilityAssessment(
                repositoryID: 2,
                states: [.actions: .available]
            ),
        ]
    )

    let summary = GitHubActionsAccessSummary.evaluate(
        repositoryIDs: [1, 2],
        assessment: assessment
    )

    #expect(summary.unverifiedRepositoryCount == 0)
    #expect(summary.unavailableRepositoryCount == 0)
}

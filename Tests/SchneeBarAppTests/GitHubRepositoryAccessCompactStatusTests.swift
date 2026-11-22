import SchneeBarGitHubFeature
import Testing

@Test
func repositoryAccessCompactSummaryOmitsAllAvailableSources() {
    let model = GitHubRepositoryActivityAccessModel(
        actions: .available,
        reviewRequests: .available,
        checks: .available,
        deployments: .available
    )
    #expect(model.compactIssueSummary == nil)
    #expect(!model.hasUnavailableSources)
    #expect(
        model.detailedAccessDescription ==
            "Actions: Available, Reviews: Available, Checks: Available, Deployments: Available"
    )
}

@Test
func repositoryAccessCompactSummaryPreservesUnavailableAndUnverifiedDistinctly() {
    let model = GitHubRepositoryActivityAccessModel(
        actions: .unavailable,
        reviewRequests: .unverified,
        checks: .unavailable,
        deployments: .available
    )
    #expect(model.compactIssueSummary == "2 unavailable · 1 unverified")
    #expect(model.hasUnavailableSources)
    #expect(
        model.detailedAccessDescription ==
            "Actions: Unavailable, Reviews: Unverified, Checks: Unavailable, Deployments: Available"
    )
}

@Test
func repositoryAccessCompactSummaryShowsUnverifiedWithoutClaimingDenial() {
    let model = GitHubRepositoryActivityAccessModel(
        actions: .available,
        reviewRequests: .unverified,
        checks: .available,
        deployments: .unverified
    )
    #expect(model.compactIssueSummary == "2 unverified")
    #expect(!model.hasUnavailableSources)
    #expect(model.detailedAccessDescription.contains("Reviews: Unverified"))
    #expect(model.detailedAccessDescription.contains("Deployments: Unverified"))
    #expect(!model.detailedAccessDescription.contains("Unavailable"))
}

@Test
func repositoryAccessCompactSummaryWithOneUnavailableRemainsSpecific() {
    let model = GitHubRepositoryActivityAccessModel(
        actions: .available,
        reviewRequests: .available,
        checks: .unavailable,
        deployments: .available
    )
    #expect(model.compactIssueSummary == "1 unavailable")
    #expect(model.hasUnavailableSources)
    #expect(model.detailedAccessDescription.contains("Checks: Unavailable"))
}

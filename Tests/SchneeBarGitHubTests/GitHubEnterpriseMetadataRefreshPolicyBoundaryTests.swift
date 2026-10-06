import Foundation
import SchneeBarGitHub
import Testing

private let enterpriseMetadataBoundaryDay: TimeInterval = 24 * 60 * 60
private let enterpriseMetadataBoundaryNow = Date(
    timeIntervalSince1970: 200_000
)

@Test
func infiniteEnterpriseMetadataIntervalFallsBackToDefaultCadence() throws {
    let policy = GitHubEnterpriseMetadataRefreshPolicy(
        minimumInterval: .infinity
    )
    let connection = try enterpriseMetadataBoundaryConnection()

    #expect(policy.minimumInterval == enterpriseMetadataBoundaryDay)
    #expect(
        policy.shouldRefresh(
            connection: connection,
            lastCheckedAt: enterpriseMetadataBoundaryNow.addingTimeInterval(
                -(enterpriseMetadataBoundaryDay + 60)
            ),
            now: enterpriseMetadataBoundaryNow
        )
    )
}

@Test
func negativeInfiniteEnterpriseMetadataIntervalFallsBackToDefaultCadence() throws {
    let policy = GitHubEnterpriseMetadataRefreshPolicy(
        minimumInterval: -.infinity
    )
    let connection = try enterpriseMetadataBoundaryConnection()

    #expect(policy.minimumInterval == enterpriseMetadataBoundaryDay)
    #expect(
        policy.shouldRefresh(
            connection: connection,
            lastCheckedAt: enterpriseMetadataBoundaryNow.addingTimeInterval(
                -(enterpriseMetadataBoundaryDay + 60)
            ),
            now: enterpriseMetadataBoundaryNow
        )
    )
}

@Test
func nanEnterpriseMetadataIntervalFallsBackToDefaultCadence() throws {
    let policy = GitHubEnterpriseMetadataRefreshPolicy(
        minimumInterval: .nan
    )
    let connection = try enterpriseMetadataBoundaryConnection()

    #expect(policy.minimumInterval == enterpriseMetadataBoundaryDay)
    #expect(
        policy.shouldRefresh(
            connection: connection,
            lastCheckedAt: enterpriseMetadataBoundaryNow.addingTimeInterval(
                -(enterpriseMetadataBoundaryDay + 60)
            ),
            now: enterpriseMetadataBoundaryNow
        )
    )
}

@Test
func finiteNegativeEnterpriseMetadataIntervalStillClampsToZero() throws {
    let policy = GitHubEnterpriseMetadataRefreshPolicy(
        minimumInterval: -1
    )
    let connection = try enterpriseMetadataBoundaryConnection()

    #expect(policy.minimumInterval == 0)
    #expect(
        policy.shouldRefresh(
            connection: connection,
            lastCheckedAt: enterpriseMetadataBoundaryNow,
            now: enterpriseMetadataBoundaryNow
        )
    )
}

private func enterpriseMetadataBoundaryConnection() throws -> GitHubConnection {
    GitHubConnection(
        displayName: "Internal GitHub",
        deploymentKind: .enterpriseServer,
        webBaseURL: try #require(
            URL(string: "https://github.internal.example")
        )
    )
}

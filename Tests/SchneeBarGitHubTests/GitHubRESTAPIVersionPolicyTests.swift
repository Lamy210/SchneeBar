import Foundation
import SchneeBarGitHub
import Testing

@Test
func choosesLegacyRESTVersionForGHES320() {
    let policy = GitHubRESTAPIVersionPolicy()

    #expect(
        policy.preferredVersion(
            for: GitHubEnterpriseServerVersion(major: 3, minor: 20)
        ) == "2022-11-28"
    )
}

@Test
func choosesCurrentRESTVersionForGHES321AndNewer() {
    let policy = GitHubRESTAPIVersionPolicy()

    #expect(
        policy.preferredVersion(
            for: GitHubEnterpriseServerVersion(major: 3, minor: 21)
        ) == "2026-03-10"
    )
    #expect(
        policy.preferredVersion(
            for: GitHubEnterpriseServerVersion(major: 3, minor: 22)
        ) == "2026-03-10"
    )
    #expect(
        policy.preferredVersion(
            for: GitHubEnterpriseServerVersion(major: 3, minor: 23)
        ) == "2026-03-10"
    )
}

@Test
func unknownEnterpriseVersionDoesNotInventAPIVersion() {
    let policy = GitHubRESTAPIVersionPolicy()
    #expect(policy.preferredVersion(for: nil) == nil)
}

@Test
func connectionDerivesEnterpriseAPIVersionWhenServerVersionArrives() throws {
    var connection = GitHubConnection(
        displayName: "Internal GitHub",
        deploymentKind: .enterpriseServer,
        webBaseURL: try #require(URL(string: "https://github.internal.example"))
    )

    #expect(connection.apiVersion == nil)

    connection.applyDiscoveredServerVersion("3.20.8")
    #expect(connection.apiVersion == "2022-11-28")

    var newerConnection = GitHubConnection(
        displayName: "Internal GitHub",
        deploymentKind: .enterpriseServer,
        webBaseURL: try #require(URL(string: "https://github.internal.example"))
    )
    newerConnection.applyDiscoveredServerVersion("3.22.0")
    #expect(newerConnection.apiVersion == "2026-03-10")
}

@Test
func explicitEnterpriseAPIVersionIsNotOverwrittenByDiscovery() throws {
    var connection = GitHubConnection(
        displayName: "Internal GitHub",
        deploymentKind: .enterpriseServer,
        webBaseURL: try #require(URL(string: "https://github.internal.example")),
        apiVersion: "custom-version"
    )

    connection.applyDiscoveredServerVersion("3.22.0")
    #expect(connection.apiVersion == "custom-version")
}

@Test
func discoveredEnterpriseVersionRecomputesAutomaticallyDerivedAPIVersion() throws {
    var connection = GitHubConnection(
        displayName: "Internal GitHub",
        deploymentKind: .enterpriseServer,
        webBaseURL: try #require(URL(string: "https://github.internal.example")),
        serverVersion: "3.20.8"
    )

    #expect(connection.apiVersion == "2022-11-28")

    connection.applyDiscoveredServerVersion("3.22.0")
    #expect(connection.serverVersion == "3.22.0")
    #expect(connection.apiVersion == "2026-03-10")

    connection.applyDiscoveredServerVersion("3.20.9")
    #expect(connection.serverVersion == "3.20.9")
    #expect(connection.apiVersion == "2022-11-28")
}

@Test
func discoveredEnterpriseVersionPreservesExplicitAPIVersionOverride() throws {
    var connection = GitHubConnection(
        displayName: "Internal GitHub",
        deploymentKind: .enterpriseServer,
        webBaseURL: try #require(URL(string: "https://github.internal.example")),
        serverVersion: "3.20.8",
        apiVersion: "custom-version"
    )

    connection.applyDiscoveredServerVersion("3.22.0")

    #expect(connection.serverVersion == "3.22.0")
    #expect(connection.apiVersion == "custom-version")
}

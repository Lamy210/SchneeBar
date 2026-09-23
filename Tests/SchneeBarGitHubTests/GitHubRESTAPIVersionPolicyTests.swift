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
func choosesCurrentRESTVersionForGHES321And322() {
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
}

@Test(arguments: [
    GitHubEnterpriseServerVersion(major: 3, minor: 19),
    GitHubEnterpriseServerVersion(major: 3, minor: 23),
    GitHubEnterpriseServerVersion(major: 4, minor: 0),
])
func untestedEnterpriseReleaseDoesNotInventAPIVersion(
    version: GitHubEnterpriseServerVersion
) {
    let policy = GitHubRESTAPIVersionPolicy()
    #expect(policy.preferredVersion(for: version) == nil)
}

@Test
func unknownEnterpriseVersionDoesNotInventAPIVersion() {
    let policy = GitHubRESTAPIVersionPolicy()
    #expect(policy.preferredVersion(for: nil) == nil)
}

@Test
func connectionDerivesEnterpriseAPIVersionWhenDiscoveredVersionArrives() throws {
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

@Test
func hostedConnectionIgnoresEnterpriseServerDiscoveryMutation() throws {
    var connection = GitHubConnection(
        displayName: "GitHub.com",
        deploymentKind: .githubDotCom,
        webBaseURL: try #require(URL(string: "https://github.com")),
        apiVersion: "2026-03-10"
    )

    connection.applyDiscoveredServerVersion("3.22.0")

    #expect(connection.serverVersion == nil)
    #expect(connection.apiVersion == "2026-03-10")
}


@Test
func requestHeaderUsesCurrentVersionForHostedGitHub() throws {
    let policy = GitHubRESTAPIVersionPolicy()
    let github = GitHubConnection(
        displayName: "GitHub.com",
        deploymentKind: .githubDotCom,
        webBaseURL: try #require(URL(string: "https://github.com"))
    )
    let ghe = GitHubConnection(
        displayName: "Company GitHub",
        deploymentKind: .gheDotCom,
        webBaseURL: try #require(URL(string: "https://acme.ghe.com"))
    )

    #expect(policy.headerVersion(for: github) == GitHubRESTAPIVersionPolicy.currentVersion)
    #expect(policy.headerVersion(for: ghe) == GitHubRESTAPIVersionPolicy.currentVersion)
}

@Test
func requestHeaderPreservesTrimmedExplicitVersionOverride() throws {
    let policy = GitHubRESTAPIVersionPolicy()
    let connection = GitHubConnection(
        displayName: "Internal GitHub",
        deploymentKind: .enterpriseServer,
        webBaseURL: try #require(URL(string: "https://github.internal.example")),
        serverVersion: "3.22.0",
        apiVersion: "  custom-version  "
    )

    #expect(policy.headerVersion(for: connection) == "custom-version")
}

@Test
func requestHeaderDerivesEnterpriseVersionWhenStoredHeaderIsMissing() throws {
    let policy = GitHubRESTAPIVersionPolicy()
    var legacy = GitHubConnection(
        displayName: "Legacy GHES",
        deploymentKind: .enterpriseServer,
        webBaseURL: try #require(URL(string: "https://legacy.internal.example")),
        serverVersion: "3.20.9"
    )
    var current = GitHubConnection(
        displayName: "Current GHES",
        deploymentKind: .enterpriseServer,
        webBaseURL: try #require(URL(string: "https://current.internal.example")),
        serverVersion: "3.22.0"
    )
    legacy.apiVersion = nil
    current.apiVersion = nil

    #expect(policy.headerVersion(for: legacy) == GitHubRESTAPIVersionPolicy.legacyVersion)
    #expect(policy.headerVersion(for: current) == GitHubRESTAPIVersionPolicy.currentVersion)
}

@Test
func requestHeaderDoesNotInventVersionForUnknownEnterpriseServer() throws {
    let policy = GitHubRESTAPIVersionPolicy()
    let connection = GitHubConnection(
        displayName: "Unknown GHES",
        deploymentKind: .enterpriseServer,
        webBaseURL: try #require(URL(string: "https://unknown.internal.example"))
    )

    #expect(policy.headerVersion(for: connection) == nil)
}

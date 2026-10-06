import Foundation
import SchneeBarGitHub
import Testing

@Test
func unsafePersistedHostedAPIVersionFallsBackBeforeHeaderUse() throws {
    let policy = GitHubRESTAPIVersionPolicy()
    let connection = GitHubConnection(
        displayName: "GitHub.com",
        deploymentKind: .githubDotCom,
        webBaseURL: try #require(URL(string: "https://github.com")),
        apiVersion: "2026-03-10\r\nX-Injected: true"
    )

    #expect(
        policy.headerVersion(for: connection)
            == GitHubRESTAPIVersionPolicy.currentVersion
    )
}

@Test
func persistedAPIVersionAcceptsExactHeaderByteBudget() throws {
    let policy = GitHubRESTAPIVersionPolicy()
    let version = String(repeating: "v", count: 128)
    let connection = GitHubConnection(
        displayName: "GitHub.com",
        deploymentKind: .githubDotCom,
        webBaseURL: try #require(URL(string: "https://github.com")),
        apiVersion: version
    )

    #expect(policy.headerVersion(for: connection) == version)
}

@Test
func oversizedPersistedHostedAPIVersionFallsBackBeforeHeaderUse() throws {
    let policy = GitHubRESTAPIVersionPolicy()
    let connection = GitHubConnection(
        displayName: "GitHub.com",
        deploymentKind: .githubDotCom,
        webBaseURL: try #require(URL(string: "https://github.com")),
        apiVersion: String(repeating: "v", count: 129)
    )

    #expect(
        policy.headerVersion(for: connection)
            == GitHubRESTAPIVersionPolicy.currentVersion
    )
}

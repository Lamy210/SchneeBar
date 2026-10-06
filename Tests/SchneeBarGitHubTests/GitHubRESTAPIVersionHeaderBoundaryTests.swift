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

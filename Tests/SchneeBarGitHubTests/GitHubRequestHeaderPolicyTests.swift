import Foundation
import Testing
@testable import SchneeBarGitHub

@Test
func githubRequestHeaderPolicyAppliesStableUserAgent() throws {
    var request = URLRequest(
        url: try #require(URL(string: "https://api.github.com/meta"))
    )

    GitHubRequestHeaderPolicy.apply(to: &request)

    #expect(
        request.value(forHTTPHeaderField: "User-Agent")
            == "SchneeBar"
    )
}

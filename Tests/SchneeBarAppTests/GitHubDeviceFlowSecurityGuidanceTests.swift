import Foundation
import SchneeBarGitHubFeature
import Testing

@Test
func deviceFlowGuidanceNamesExactHostedGitHubHost() throws {
    let url = try #require(
        URL(string: "https://github.com/login/device")
    )

    #expect(githubDeviceFlowAuthorizationHost(url) == "github.com")
    #expect(
        githubDeviceFlowAntiPhishingMessage(verificationURI: url)
            == "Only enter this code at github.com after starting this authorization in SchneeBar. Never approve a device code received through chat, email, a ticket, or another app."
    )
}

@Test
func deviceFlowGuidancePreservesEnterpriseHTTPSPort() throws {
    let url = try #require(
        URL(string: "https://github.internal.example:8443/login/device")
    )

    #expect(
        githubDeviceFlowAuthorizationHost(url)
            == "github.internal.example:8443"
    )
}

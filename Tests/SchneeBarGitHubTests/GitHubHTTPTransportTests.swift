import Foundation
import Testing
@testable import SchneeBarGitHub

@Test
func defaultGitHubTransportConfigurationAvoidsPersistentHTTPState() {
    let configuration =
        URLSessionGitHubHTTPTransport.defaultConfiguration()

    #expect(!configuration.httpShouldSetCookies)
    #expect(configuration.httpCookieStorage == nil)
    #expect(configuration.urlCredentialStorage == nil)
    #expect(configuration.urlCache == nil)
    #expect(configuration.identifier == nil)
}

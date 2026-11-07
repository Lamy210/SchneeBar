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


private final class GitHubRedirectDecisionProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var invoked = false
    private var accepted = false

    func record(_ decision: URLRequest?) {
        lock.lock()
        defer { lock.unlock() }
        invoked = true
        accepted = decision != nil
    }

    var result: (invoked: Bool, accepted: Bool) {
        lock.lock()
        defer { lock.unlock() }
        return (invoked, accepted)
    }
}

@Test
func githubTransportRejectsRedirectsToForeignOrSameOrigin() throws {
    let session = URLSession(configuration: .ephemeral)
    defer { session.invalidateAndCancel() }

    let original = try #require(URL(string: "https://api.github.com/user"))
    let delegate = GitHubNoRedirectDelegate()
    let task = session.dataTask(with: original)
    defer { task.cancel() }
    let probe = GitHubRedirectDecisionProbe()

    for target in [
        "https://redirected.invalid/steal-token",
        "http://api.github.com/unsafe",
        "https://api.github.com:8443/other-port",
        "https://api.github.com/same-origin",
    ] {
        let response = try #require(HTTPURLResponse(
            url: original,
            statusCode: 307,
            httpVersion: "HTTP/1.1",
            headerFields: ["Location": target]
        ))
        let destination = try #require(URL(string: target))
        delegate.urlSession(
            session,
            task: task,
            willPerformHTTPRedirection: response,
            newRequest: URLRequest(url: destination),
            completionHandler: { newRequest in probe.record(newRequest) }
        )
        #expect(probe.result.invoked)
        #expect(!probe.result.accepted)
    }
}

private final class GitHubRedirectStatusURLProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        guard let url = request.url,
              let response = HTTPURLResponse(
                  url: url,
                  statusCode: 302,
                  httpVersion: "HTTP/1.1",
                  headerFields: ["Location": "https://redirected.invalid/private"]
              )
        else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data())
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

@Test
func githubTransportNeverTreatsRedirectResponseAsSuccess() async throws {
    let configuration = URLSessionGitHubHTTPTransport.defaultConfiguration()
    configuration.protocolClasses = [GitHubRedirectStatusURLProtocol.self]
    let session = URLSession(configuration: configuration)
    defer { session.invalidateAndCancel() }

    let transport = URLSessionGitHubHTTPTransport(session: session)
    let url = try #require(URL(string: "https://github.transport.test/private"))
    var request = URLRequest(url: url)
    request.setValue("Bearer fake-secret", forHTTPHeaderField: "Authorization")

    do {
        _ = try await transport.data(for: request)
        Issue.record("A redirect response must not be treated as API success")
    } catch {
        #expect(error as? GitHubHTTPTransportError == .redirectRejected)
    }
}

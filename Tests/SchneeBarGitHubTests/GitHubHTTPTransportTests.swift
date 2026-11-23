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
    #expect(URLSessionGitHubHTTPTransport.isSafeForCredentialRequests(configuration))
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


@Test
func githubCredentialTransportPolicyRejectsEachPersistentStateSink() {
    let safe = URLSessionGitHubHTTPTransport.defaultConfiguration()
    #expect(URLSessionGitHubHTTPTransport.isSafeForCredentialRequests(safe))

    let cookiesEnabled = URLSessionGitHubHTTPTransport.defaultConfiguration()
    cookiesEnabled.httpShouldSetCookies = true
    #expect(!URLSessionGitHubHTTPTransport.isSafeForCredentialRequests(cookiesEnabled))

    let cookieStorage = URLSessionGitHubHTTPTransport.defaultConfiguration()
    cookieStorage.httpCookieStorage = HTTPCookieStorage.shared
    #expect(!URLSessionGitHubHTTPTransport.isSafeForCredentialRequests(cookieStorage))

    let credentials = URLSessionGitHubHTTPTransport.defaultConfiguration()
    credentials.urlCredentialStorage = URLCredentialStorage.shared
    #expect(!URLSessionGitHubHTTPTransport.isSafeForCredentialRequests(credentials))

    let cache = URLSessionGitHubHTTPTransport.defaultConfiguration()
    cache.urlCache = URLCache(memoryCapacity: 1_024, diskCapacity: 0, diskPath: nil)
    #expect(!URLSessionGitHubHTTPTransport.isSafeForCredentialRequests(cache))
}

@Test
func githubTransportRejectsInjectedPersistentSessionBeforeRequest() async throws {
    let configuration = URLSessionConfiguration.default
    // Prevent any real network access even if the unsafe-configuration
    // check regresses: this protocol returns only a synthetic 302.
    configuration.protocolClasses = [GitHubRedirectStatusURLProtocol.self]
    let session = URLSession(configuration: configuration)
    defer { session.invalidateAndCancel() }

    let transport = URLSessionGitHubHTTPTransport(session: session)
    let url = try #require(URL(string: "https://github.transport.test/secret"))
    var request = URLRequest(url: url)
    request.setValue("Bearer synthetic-test-only", forHTTPHeaderField: "Authorization")

    do {
        _ = try await transport.data(for: request)
        Issue.record("Injected persistent URLSession must be rejected")
    } catch {
        #expect(error as? GitHubHTTPTransportError == .unsafeSessionConfiguration)
    }
}


@Test
func githubTransportRejectsUnsafeInitialCredentialURLsBeforeNetwork() async throws {
    let configuration = URLSessionGitHubHTTPTransport.defaultConfiguration()
    // If preflight fails open, this synthetic protocol returns a 302.
    // No production network destination is used by this test.
    configuration.protocolClasses = [GitHubRedirectStatusURLProtocol.self]
    let session = URLSession(configuration: configuration)
    defer { session.invalidateAndCancel() }

    let transport = URLSessionGitHubHTTPTransport(session: session)
    let unsafeURLs = [
        "http://github.transport.test/user",
        "https://user:password@github.transport.test/user",
        "https://github.transport.test/user#token-fragment",
        "https://github.transport.test:0/user",
    ]

    for rawURL in unsafeURLs {
        let url = try #require(URL(string: rawURL))
        var request = URLRequest(url: url)
        request.setValue(
            "Bearer synthetic-test-only",
            forHTTPHeaderField: "Authorization"
        )
        await #expect(throws: GitHubHTTPTransportError.unsafeRequestURL) {
            try await transport.data(for: request)
        }
    }
}

@Test
func githubTransportPermitsValidInitialHTTPSURLToReachResponseHandling() async throws {
    let configuration = URLSessionGitHubHTTPTransport.defaultConfiguration()
    configuration.protocolClasses = [GitHubRedirectStatusURLProtocol.self]
    let session = URLSession(configuration: configuration)
    defer { session.invalidateAndCancel() }

    let transport = URLSessionGitHubHTTPTransport(session: session)
    var request = URLRequest(
        url: try #require(URL(string: "https://github.transport.test:8443/user"))
    )
    request.setValue(
        "Bearer synthetic-test-only",
        forHTTPHeaderField: "Authorization"
    )
    // A well-formed initial URL passes preflight, but a 302 remains blocked.
    await #expect(throws: GitHubHTTPTransportError.redirectRejected) {
        try await transport.data(for: request)
    }
}

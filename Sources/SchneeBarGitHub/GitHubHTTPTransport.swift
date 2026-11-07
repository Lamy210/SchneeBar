import Foundation

public enum GitHubHTTPTransportError: Error, Equatable, Sendable {
    case nonHTTPResponse
    case redirectRejected
    case unsupportedBackgroundSession
}

public protocol GitHubHTTPTransport: Sendable {
    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

public struct URLSessionGitHubHTTPTransport: GitHubHTTPTransport {
    private static let defaultSession = URLSession(
        configuration: defaultConfiguration()
    )
    // A per-task delegate applies even when a caller injects its own session.
    private static let noRedirectDelegate = GitHubNoRedirectDelegate()

    private let session: URLSession

    public init() {
        self.init(session: Self.defaultSession)
    }

    public init(session: URLSession) {
        self.session = session
    }

    static func defaultConfiguration() -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpShouldSetCookies = false
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        configuration.urlCache = nil
        return configuration
    }

    public func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        // Apple does not deliver the redirect callback for background sessions.
        // Reject an injected background configuration before sending secrets.
        guard session.configuration.identifier == nil else {
            throw GitHubHTTPTransportError.unsupportedBackgroundSession
        }

        let (data, response) = try await session.data(
            for: request,
            delegate: Self.noRedirectDelegate
        )
        guard let httpResponse = response as? HTTPURLResponse else {
            throw GitHubHTTPTransportError.nonHTTPResponse
        }
        // Refusing a redirect returns the original 30x response. Do not make
        // callers interpret that body or Location header as an API result.
        guard !(300 ... 399).contains(httpResponse.statusCode) else {
            throw GitHubHTTPTransportError.redirectRejected
        }
        return (data, httpResponse)
    }
}

/// GitHub API and OAuth requests can carry bearer credentials or device codes.
/// Never automatically forward them, even to the same host: the application
/// builds canonical API endpoints itself and does not rely on redirects.
/// Apple invokes this callback for ephemeral/default URLSession tasks.
final class GitHubNoRedirectDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping @Sendable (URLRequest?) -> Void
    ) {
        completionHandler(nil)
    }
}

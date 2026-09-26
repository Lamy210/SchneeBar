import Foundation

public enum GitHubHTTPTransportError: Error, Equatable, Sendable {
    case nonHTTPResponse
}

public protocol GitHubHTTPTransport: Sendable {
    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

public struct URLSessionGitHubHTTPTransport: GitHubHTTPTransport {
    private static let defaultSession = URLSession(
        configuration: defaultConfiguration()
    )

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
        configuration.urlCache = nil
        return configuration
    }

    public func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw GitHubHTTPTransportError.nonHTTPResponse
        }
        return (data, httpResponse)
    }
}

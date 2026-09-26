import Foundation

enum GitHubRequestHeaderPolicy {
    static let userAgent = "SchneeBar"

    static func apply(to request: inout URLRequest) {
        request.setValue(
            userAgent,
            forHTTPHeaderField: "User-Agent"
        )
    }
}

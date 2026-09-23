import Foundation

public enum GitHubSSOFailureSignal: Equatable, Sendable {
    case required
    case other

    init(headerValue: String) {
        let directive = headerValue
            .split(separator: ";", maxSplits: 1, omittingEmptySubsequences: true)
            .first
            .map(String.init)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()

        self = directive == "required" ? .required : .other
    }
}

public struct GitHubHTTPFailureEvidence: Equatable, Sendable {
    public let statusCode: Int
    public let ssoSignal: GitHubSSOFailureSignal

    public init(
        statusCode: Int,
        ssoSignal: GitHubSSOFailureSignal
    ) {
        self.statusCode = statusCode
        self.ssoSignal = ssoSignal
    }

    static func sanitized(
        from response: HTTPURLResponse
    ) -> GitHubHTTPFailureEvidence? {
        guard let headerValue = response.value(
            forHTTPHeaderField: "X-GitHub-SSO"
        ) else {
            return nil
        }
        return GitHubHTTPFailureEvidence(
            statusCode: response.statusCode,
            ssoSignal: GitHubSSOFailureSignal(
                headerValue: headerValue
            )
        )
    }
}

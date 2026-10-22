import Foundation

public enum GitHubDeviceAuthorizationWaitError: Error, Equatable, Sendable {
    case accessDenied
    case expired
}

public struct GitHubDeviceAuthorizationWaiter: Sendable {
    public typealias Sleeper = @Sendable (_ seconds: TimeInterval) async throws -> Void

    private let client: GitHubDeviceFlowClient
    private let sleeper: Sleeper

    public init(
        client: GitHubDeviceFlowClient = GitHubDeviceFlowClient(),
        sleeper: @escaping Sleeper = { seconds in
            let roundedSeconds = max(1, Int64(seconds.rounded(.up)))
            try await Task.sleep(for: .seconds(roundedSeconds))
        }
    ) {
        self.client = client
        self.sleeper = sleeper
    }

    public func waitForAuthorization(
        connection: GitHubConnection,
        clientID: String,
        session: GitHubDeviceAuthorizationSession,
        repositoryID: String? = nil
    ) async throws -> GitHubCredential {
        guard GitHubDeviceFlowTimingPolicy.isValidPollInterval(
            session.pollInterval
        ) else {
            throw GitHubDeviceFlowError.invalidResponse
        }
        var delay = session.pollInterval

        while true {
            try Task.checkCancellation()
            try await sleeper(delay)
            try Task.checkCancellation()

            let result = try await client.pollOnce(
                connection: connection,
                clientID: clientID,
                session: session,
                repositoryID: repositoryID
            )

            switch result {
            case let .pending(retryAfter):
                // Never decrease a delay that was already raised by `slow_down`.
                let nextDelay = max(delay, retryAfter)
                guard GitHubDeviceFlowTimingPolicy
                    .isValidPollInterval(nextDelay)
                else {
                    throw GitHubDeviceFlowError.invalidResponse
                }
                delay = nextDelay

            case let .slowDown(retryAfter):
                // RFC 8628 / GitHub Device Flow requires adding at least five
                // seconds after each slow_down response. `pollOnce` is stateless,
                // so cumulative backoff belongs in this coordinator.
                let nextDelay = max(retryAfter, delay + 5)
                guard GitHubDeviceFlowTimingPolicy
                    .isValidPollInterval(nextDelay)
                else {
                    throw GitHubDeviceFlowError.invalidResponse
                }
                delay = nextDelay

            case let .authorized(credential):
                return credential

            case .accessDenied:
                throw GitHubDeviceAuthorizationWaitError.accessDenied

            case .expired:
                throw GitHubDeviceAuthorizationWaitError.expired
            }
        }
    }
}

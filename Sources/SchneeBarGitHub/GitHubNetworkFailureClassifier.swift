import Foundation

public enum GitHubNetworkFailureKind: Equatable, Sendable {
    case offline
    case hostResolution
    case connection
    case timedOut
    case connectionLost
}

public enum GitHubNetworkFailureClassifier {
    public static func classify(_ error: Error) -> GitHubNetworkFailureKind? {
        guard let code = urlErrorCode(for: error) else {
            return nil
        }

        switch code {
        case .notConnectedToInternet:
            return .offline
        case .cannotFindHost, .dnsLookupFailed:
            return .hostResolution
        case .cannotConnectToHost:
            return .connection
        case .timedOut:
            return .timedOut
        case .networkConnectionLost:
            return .connectionLost
        default:
            return nil
        }
    }

    public static func isUnavailable(_ error: Error) -> Bool {
        classify(error) != nil
    }

    private static func urlErrorCode(for error: Error) -> URLError.Code? {
        if let urlError = error as? URLError {
            return urlError.code
        }

        let nsError = error as NSError
        guard nsError.domain == NSURLErrorDomain else {
            return nil
        }
        return URLError.Code(rawValue: nsError.code)
    }
}

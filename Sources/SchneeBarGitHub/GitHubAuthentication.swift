import Foundation

public enum GitHubAuthenticationMethod: String, Codable, Sendable {
    case deviceFlow
    case fineGrainedPersonalAccessToken
}

public struct GitHubAccountIdentity: Codable, Equatable, Sendable {
    public let id: String
    public let login: String

    public init(id: String, login: String) {
        self.id = id
        self.login = login
    }
}

public enum GitHubPresentationTextPolicy {
    public static func hasSafeScalars(_ value: String) -> Bool {
        !value.unicodeScalars.contains(where: {
            switch $0.properties.generalCategory {
            case .control, .format, .lineSeparator,
                 .paragraphSeparator:
                true
            default:
                false
            }
        })
    }
}

public enum GitHubAccountIdentityPolicy {
    // Defensive presentation budget only; this is intentionally not a
    // GitHub username syntax rule so GHES/managed-account naming can evolve.
    public static let maximumLoginCharacters = 256
    public static let maximumLoginUTF8Bytes = 1_024

    public static func isValidLogin(_ login: String) -> Bool {
        guard !login.isEmpty,
              login == login.trimmingCharacters(
                  in: .whitespacesAndNewlines
              ),
              login.count <= maximumLoginCharacters,
              login.utf8.count <= maximumLoginUTF8Bytes,
              GitHubPresentationTextPolicy.hasSafeScalars(login)
        else {
            return false
        }
        return true
    }
}

public struct GitHubCredential: Codable, Equatable, Sendable {
    public let accessToken: String
    public let refreshToken: String?
    public let accessTokenExpiresAt: Date?
    public let refreshTokenExpiresAt: Date?
    /// Canonical web endpoint that this credential was established against.
    /// Legacy credentials decode with nil and are handled by the session
    /// coordinator according to deployment kind.
    public let endpointIdentity: String?

    public init(
        accessToken: String,
        refreshToken: String? = nil,
        accessTokenExpiresAt: Date? = nil,
        refreshTokenExpiresAt: Date? = nil,
        endpointIdentity: String? = nil
    ) {
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.accessTokenExpiresAt = accessTokenExpiresAt
        self.refreshTokenExpiresAt = refreshTokenExpiresAt
        self.endpointIdentity = endpointIdentity
    }
}

public struct GitHubCredentialKey: Hashable, Sendable {
    public let connectionID: UUID
    public let accountID: String

    public init(connectionID: UUID, accountID: String) {
        self.connectionID = connectionID
        self.accountID = accountID
    }

    public var storageAccount: String {
        "\(connectionID.uuidString.lowercased()):\(accountID)"
    }
}

public protocol GitHubCredentialStore: Sendable {
    func load(for key: GitHubCredentialKey) async throws -> GitHubCredential?
    func save(_ credential: GitHubCredential, for key: GitHubCredentialKey) async throws
    func delete(for key: GitHubCredentialKey) async throws
}

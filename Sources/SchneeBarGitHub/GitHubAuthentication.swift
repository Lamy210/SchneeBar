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

public struct GitHubCredential: Codable, Equatable, Sendable {
    public let accessToken: String
    public let refreshToken: String?
    public let accessTokenExpiresAt: Date?
    public let refreshTokenExpiresAt: Date?

    public init(
        accessToken: String,
        refreshToken: String? = nil,
        accessTokenExpiresAt: Date? = nil,
        refreshTokenExpiresAt: Date? = nil
    ) {
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.accessTokenExpiresAt = accessTokenExpiresAt
        self.refreshTokenExpiresAt = refreshTokenExpiresAt
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

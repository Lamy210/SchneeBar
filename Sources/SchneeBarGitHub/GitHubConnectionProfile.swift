import Foundation

public enum GitHubRepositoryMonitoringSelection: Equatable, Sendable {
    case allAccessible
    case selected(Set<Int64>)

    public func includes(repositoryID: Int64) -> Bool {
        switch self {
        case .allAccessible:
            return true
        case let .selected(ids):
            return ids.contains(repositoryID)
        }
    }
}

extension GitHubRepositoryMonitoringSelection: Codable {
    private enum Mode: String, Codable {
        case allAccessible
        case selected
    }

    private enum CodingKeys: String, CodingKey {
        case mode
        case repositoryIDs
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(Mode.self, forKey: .mode) {
        case .allAccessible:
            self = .allAccessible
        case .selected:
            let ids = try container.decode([Int64].self, forKey: .repositoryIDs)
            self = .selected(Set(ids))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .allAccessible:
            try container.encode(Mode.allAccessible, forKey: .mode)
        case let .selected(ids):
            try container.encode(Mode.selected, forKey: .mode)
            try container.encode(ids.sorted(), forKey: .repositoryIDs)
        }
    }
}

public struct GitHubConnectionProfile: Identifiable, Codable, Equatable, Sendable {
    public var id: UUID { connection.id }

    public var connection: GitHubConnection
    public var account: GitHubAccountIdentity
    public var authenticationMethod: GitHubAuthenticationMethod
    public var clientID: String?
    public var repositorySelection: GitHubRepositoryMonitoringSelection
    public var isEnabled: Bool
    public var createdAt: Date
    public var lastConnectedAt: Date?

    public init(
        connection: GitHubConnection,
        account: GitHubAccountIdentity,
        authenticationMethod: GitHubAuthenticationMethod,
        clientID: String? = nil,
        repositorySelection: GitHubRepositoryMonitoringSelection = .allAccessible,
        isEnabled: Bool = true,
        createdAt: Date = .now,
        lastConnectedAt: Date? = nil
    ) {
        self.connection = connection
        self.account = account
        self.authenticationMethod = authenticationMethod
        self.clientID = clientID
        self.repositorySelection = repositorySelection
        self.isEnabled = isEnabled
        self.createdAt = createdAt
        self.lastConnectedAt = lastConnectedAt
    }

    public var credentialKey: GitHubCredentialKey {
        GitHubCredentialKey(
            connectionID: connection.id,
            accountID: account.id
        )
    }
}

public protocol GitHubConnectionProfileStore: Sendable {
    func loadAll() async throws -> [GitHubConnectionProfile]
    func load(id: UUID) async throws -> GitHubConnectionProfile?
    func save(_ profile: GitHubConnectionProfile) async throws
    func delete(id: UUID) async throws
}

import Foundation

public struct GitHubConnectionSession: Equatable, Sendable {
    public let connectionID: UUID
    public let account: GitHubAuthenticatedAccount
    public let credentialKey: GitHubCredentialKey
    public let inventory: GitHubAccessInventory

    public init(
        connectionID: UUID,
        account: GitHubAuthenticatedAccount,
        credentialKey: GitHubCredentialKey,
        inventory: GitHubAccessInventory
    ) {
        self.connectionID = connectionID
        self.account = account
        self.credentialKey = credentialKey
        self.inventory = inventory
    }
}

public enum GitHubConnectionSessionError: Error, Equatable, Sendable {
    case credentialNotFound
    case reauthenticationRequired
    case accountMismatch(expectedID: String, actualID: String)
}

public actor GitHubConnectionSessionCoordinator {
    private let credentialStore: any GitHubCredentialStore
    private let accessClient: GitHubAccessClient
    private let deviceFlowClient: GitHubDeviceFlowClient
    private let now: @Sendable () -> Date
    private let refreshLeeway: TimeInterval

    public init(
        credentialStore: any GitHubCredentialStore,
        accessClient: GitHubAccessClient = GitHubAccessClient(),
        deviceFlowClient: GitHubDeviceFlowClient = GitHubDeviceFlowClient(),
        now: @escaping @Sendable () -> Date = { .now },
        refreshLeeway: TimeInterval = 300
    ) {
        self.credentialStore = credentialStore
        self.accessClient = accessClient
        self.deviceFlowClient = deviceFlowClient
        self.now = now
        self.refreshLeeway = max(0, refreshLeeway)
    }

    public func establish(
        connection: GitHubConnection,
        credential: GitHubCredential
    ) async throws -> GitHubConnectionSession {
        let account = try await accessClient.authenticatedAccount(
            connection: connection,
            credential: credential
        )
        let key = credentialKey(connection: connection, identity: account.identity)

        try await credentialStore.save(credential, for: key)

        do {
            let inventory = try await accessClient.inventory(
                connection: connection,
                credential: credential
            )
            return GitHubConnectionSession(
                connectionID: connection.id,
                account: account,
                credentialKey: key,
                inventory: inventory
            )
        } catch GitHubAccessClientError.httpStatus(401) {
            try? await credentialStore.delete(for: key)
            throw GitHubConnectionSessionError.reauthenticationRequired
        }
    }

    public func restore(
        connection: GitHubConnection,
        identity: GitHubAccountIdentity,
        clientID: String? = nil
    ) async throws -> GitHubConnectionSession {
        let key = credentialKey(connection: connection, identity: identity)
        let credential = try await authorizedCredential(
            connection: connection,
            identity: identity,
            clientID: clientID
        )

        let account: GitHubAuthenticatedAccount
        do {
            account = try await accessClient.authenticatedAccount(
                connection: connection,
                credential: credential
            )
        } catch GitHubAccessClientError.httpStatus(401) {
            throw GitHubConnectionSessionError.reauthenticationRequired
        }

        guard account.identity.id == identity.id else {
            throw GitHubConnectionSessionError.accountMismatch(
                expectedID: identity.id,
                actualID: account.identity.id
            )
        }

        let inventory: GitHubAccessInventory
        do {
            inventory = try await accessClient.inventory(
                connection: connection,
                credential: credential
            )
        } catch GitHubAccessClientError.httpStatus(401) {
            throw GitHubConnectionSessionError.reauthenticationRequired
        }

        return GitHubConnectionSession(
            connectionID: connection.id,
            account: account,
            credentialKey: key,
            inventory: inventory
        )
    }

    public func disconnect(
        connection: GitHubConnection,
        identity: GitHubAccountIdentity
    ) async throws {
        let key = credentialKey(connection: connection, identity: identity)
        try await credentialStore.delete(for: key)
    }

    /// Returns a usable credential for an already-established account without
    /// repeating identity or repository-inventory discovery. This is kept
    /// module-internal so bearer credentials cannot leak into app/UI layers.
    func authorizedCredential(
        connection: GitHubConnection,
        identity: GitHubAccountIdentity,
        clientID: String? = nil
    ) async throws -> GitHubCredential {
        let key = credentialKey(connection: connection, identity: identity)
        guard var credential = try await credentialStore.load(for: key) else {
            throw GitHubConnectionSessionError.credentialNotFound
        }

        guard shouldRefresh(credential) else {
            return credential
        }

        guard let clientID,
              let refreshToken = credential.refreshToken,
              !refreshToken.isEmpty,
              refreshTokenIsUsable(credential)
        else {
            throw GitHubConnectionSessionError.reauthenticationRequired
        }

        credential = try await deviceFlowClient.refresh(
            connection: connection,
            clientID: clientID,
            credential: credential
        )
        try await credentialStore.save(credential, for: key)
        return credential
    }

    private func credentialKey(
        connection: GitHubConnection,
        identity: GitHubAccountIdentity
    ) -> GitHubCredentialKey {
        GitHubCredentialKey(
            connectionID: connection.id,
            accountID: identity.id
        )
    }

    private func shouldRefresh(_ credential: GitHubCredential) -> Bool {
        guard let expiresAt = credential.accessTokenExpiresAt else {
            return false
        }
        return expiresAt <= now().addingTimeInterval(refreshLeeway)
    }

    private func refreshTokenIsUsable(_ credential: GitHubCredential) -> Bool {
        guard let expiresAt = credential.refreshTokenExpiresAt else {
            return true
        }
        return expiresAt > now().addingTimeInterval(refreshLeeway)
    }
}

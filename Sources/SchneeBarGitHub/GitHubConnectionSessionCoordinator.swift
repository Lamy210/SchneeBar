import Foundation

public struct GitHubConnectionSession: Equatable, Sendable {
    public let connectionID: UUID
    public let account: GitHubAuthenticatedAccount
    public let credentialKey: GitHubCredentialKey
    public let inventory: GitHubAccessInventory
    public let capabilities: GitHubConnectionCapabilityAssessment

    public init(
        connectionID: UUID,
        account: GitHubAuthenticatedAccount,
        credentialKey: GitHubCredentialKey,
        inventory: GitHubAccessInventory,
        capabilities: GitHubConnectionCapabilityAssessment
    ) {
        self.connectionID = connectionID
        self.account = account
        self.credentialKey = credentialKey
        self.inventory = inventory
        self.capabilities = capabilities
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
    private let capabilityEvaluator: GitHubCapabilityEvaluator
    private let now: @Sendable () -> Date
    private let refreshLeeway: TimeInterval
    private var refreshTasks: [GitHubCredentialKey: Task<GitHubCredential, Error>] = [:]

    public init(
        credentialStore: any GitHubCredentialStore,
        accessClient: GitHubAccessClient = GitHubAccessClient(),
        deviceFlowClient: GitHubDeviceFlowClient = GitHubDeviceFlowClient(),
        capabilityEvaluator: GitHubCapabilityEvaluator = .init(),
        now: @escaping @Sendable () -> Date = { .now },
        refreshLeeway: TimeInterval = 300
    ) {
        self.credentialStore = credentialStore
        self.accessClient = accessClient
        self.deviceFlowClient = deviceFlowClient
        self.capabilityEvaluator = capabilityEvaluator
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
            let capabilities = capabilityEvaluator.evaluate(
                connection: connection,
                inventory: inventory
            )
            return GitHubConnectionSession(
                connectionID: connection.id,
                account: account,
                credentialKey: key,
                inventory: inventory,
                capabilities: capabilities
            )
        } catch GitHubAccessClientError.httpStatus(401) {
            try? await credentialStore.delete(for: key)
            throw GitHubConnectionSessionError.reauthenticationRequired
        }
    }

    public func rebindEstablishedSession(
        _ session: GitHubConnectionSession,
        from sourceConnection: GitHubConnection,
        to targetConnection: GitHubConnection
    ) async throws -> GitHubConnectionSession {
        let sourceKey = credentialKey(
            connection: sourceConnection,
            identity: session.account.identity
        )
        guard sourceKey == session.credentialKey,
              let credential = try await credentialStore.load(for: sourceKey)
        else {
            throw GitHubConnectionSessionError.credentialNotFound
        }

        let targetKey = credentialKey(
            connection: targetConnection,
            identity: session.account.identity
        )
        let capabilities = capabilityEvaluator.evaluate(
            connection: targetConnection,
            inventory: session.inventory
        )

        guard targetKey != sourceKey else {
            return GitHubConnectionSession(
                connectionID: targetConnection.id,
                account: session.account,
                credentialKey: targetKey,
                inventory: session.inventory,
                capabilities: capabilities
            )
        }

        let previousTargetCredential = try await credentialStore.load(for: targetKey)
        refreshTasks[sourceKey]?.cancel()
        refreshTasks[sourceKey] = nil
        refreshTasks[targetKey]?.cancel()
        refreshTasks[targetKey] = nil

        try await credentialStore.save(credential, for: targetKey)
        do {
            try await credentialStore.delete(for: sourceKey)
        } catch {
            if let previousTargetCredential {
                try? await credentialStore.save(previousTargetCredential, for: targetKey)
            } else {
                try? await credentialStore.delete(for: targetKey)
            }
            throw error
        }

        return GitHubConnectionSession(
            connectionID: targetConnection.id,
            account: session.account,
            credentialKey: targetKey,
            inventory: session.inventory,
            capabilities: capabilities
        )
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

        let capabilities = capabilityEvaluator.evaluate(
            connection: connection,
            inventory: inventory
        )
        return GitHubConnectionSession(
            connectionID: connection.id,
            account: account,
            credentialKey: key,
            inventory: inventory,
            capabilities: capabilities
        )
    }

    public func disconnect(
        connection: GitHubConnection,
        identity: GitHubAccountIdentity
    ) async throws {
        let key = credentialKey(connection: connection, identity: identity)
        refreshTasks[key]?.cancel()
        refreshTasks[key] = nil
        try await credentialStore.delete(for: key)
    }

    /// Returns a usable credential for an already-established account without
    /// repeating identity or repository-inventory discovery. This is kept
    /// module-internal so bearer credentials cannot leak into app/UI layers.
    ///
    /// Refresh-token rotation is single-flight per connection/account. GitHub
    /// may rotate refresh tokens, so concurrent repository polling must never
    /// send the same old refresh token more than once.
    func authorizedCredential(
        connection: GitHubConnection,
        identity: GitHubAccountIdentity,
        clientID: String? = nil
    ) async throws -> GitHubCredential {
        let key = credentialKey(connection: connection, identity: identity)

        if let refreshTask = refreshTasks[key] {
            return try await refreshTask.value
        }

        guard let credential = try await credentialStore.load(for: key) else {
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

        let deviceFlowClient = self.deviceFlowClient
        let credentialStore = self.credentialStore
        let refreshTask = Task<GitHubCredential, Error> {
            let refreshed = try await deviceFlowClient.refresh(
                connection: connection,
                clientID: clientID,
                credential: credential
            )
            try await credentialStore.save(refreshed, for: key)
            return refreshed
        }
        refreshTasks[key] = refreshTask

        do {
            let refreshed = try await refreshTask.value
            refreshTasks[key] = nil
            return refreshed
        } catch {
            refreshTasks[key] = nil
            throw error
        }
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

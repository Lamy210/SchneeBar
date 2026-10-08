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
    case ssoRequired
    case accountMismatch(expectedID: String, actualID: String)
    case connectionEndpointMismatch
}

public actor GitHubConnectionSessionCoordinator {
    private let credentialStore: any GitHubCredentialStore
    private let accessClient: GitHubAccessClient
    private let deviceFlowClient: GitHubDeviceFlowClient
    private let capabilityEvaluator: GitHubCapabilityEvaluator
    private let now: @Sendable () -> Date
    private let refreshLeeway: TimeInterval

    private struct RefreshFlight {
        let id: UInt64
        let generation: UInt64
        let task: Task<GitHubCredential, Error>
        var failureObserved: Bool
    }

    private var refreshTasks: [GitHubCredentialKey: RefreshFlight] = [:]
    private var refreshGenerationByKey: [GitHubCredentialKey: UInt64] = [:]
    private var nextRefreshSequence: UInt64 = 0
    private var credentialMutationKeys: Set<GitHubCredentialKey> = []
    private var credentialMutationGenerationByKey: [GitHubCredentialKey: UInt64] = [:]
    private var credentialMutationWaiters: [CheckedContinuation<Void, Never>] = []

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
        let account: GitHubAuthenticatedAccount
        do {
            account = try await accessClient.authenticatedAccount(
                connection: connection,
                credential: credential
            )
        } catch let error as GitHubAccessClientError
            where isSSORequired(error)
        {
            throw GitHubConnectionSessionError.ssoRequired
        }

        try Task.checkCancellation()
        let key = credentialKey(connection: connection, identity: account.identity)

        let inventory: GitHubAccessInventory
        do {
            inventory = try await accessClient.inventory(
                connection: connection,
                credential: credential
            )
        } catch let error as GitHubAccessClientError where error.statusCode == 401 {
            throw GitHubConnectionSessionError.reauthenticationRequired
        } catch let error as GitHubAccessClientError
            where isSSORequired(error)
        {
            throw GitHubConnectionSessionError.ssoRequired
        }

        try validateInventoryIdentity(
            inventory,
            expectedID: account.identity.id
        )
        let validatedAccount = inventory.account

        let capabilities = capabilityEvaluator.evaluate(
            connection: connection,
            inventory: inventory
        )
        let persistedCredential = try boundCredential(
            credential,
            to: connection
        )

        try Task.checkCancellation()
        try await credentialStore.save(persistedCredential, for: key)

        return GitHubConnectionSession(
            connectionID: connection.id,
            account: validatedAccount,
            credentialKey: key,
            inventory: inventory,
            capabilities: capabilities
        )
    }

    public func recover(
        connection: GitHubConnection,
        expectedIdentity: GitHubAccountIdentity,
        credential: GitHubCredential
    ) async throws -> GitHubConnectionSession {
        let account: GitHubAuthenticatedAccount
        do {
            account = try await accessClient.authenticatedAccount(
                connection: connection,
                credential: credential
            )
        } catch let error as GitHubAccessClientError where error.statusCode == 401 {
            throw GitHubConnectionSessionError.reauthenticationRequired
        } catch let error as GitHubAccessClientError
            where isSSORequired(error)
        {
            throw GitHubConnectionSessionError.ssoRequired
        }

        guard account.identity.id == expectedIdentity.id else {
            throw GitHubConnectionSessionError.accountMismatch(
                expectedID: expectedIdentity.id,
                actualID: account.identity.id
            )
        }

        let inventory: GitHubAccessInventory
        do {
            inventory = try await accessClient.inventory(
                connection: connection,
                credential: credential
            )
        } catch let error as GitHubAccessClientError where error.statusCode == 401 {
            throw GitHubConnectionSessionError.reauthenticationRequired
        } catch let error as GitHubAccessClientError
            where isSSORequired(error)
        {
            throw GitHubConnectionSessionError.ssoRequired
        }

        try validateInventoryIdentity(
            inventory,
            expectedID: account.identity.id
        )

        let capabilities = capabilityEvaluator.evaluate(
            connection: connection,
            inventory: inventory
        )
        let key = credentialKey(connection: connection, identity: expectedIdentity)

        try Task.checkCancellation()
        let mutationKeys: Set<GitHubCredentialKey> = [key]
        await acquireCredentialMutation(for: mutationKeys)
        defer {
            releaseCredentialMutation(for: mutationKeys)
        }
        try Task.checkCancellation()
        await cancelAndDrainRefreshTask(for: key)
        try Task.checkCancellation()
        let persistedCredential = try boundCredential(
            credential,
            to: connection
        )
        try await credentialStore.save(persistedCredential, for: key)

        return GitHubConnectionSession(
            connectionID: connection.id,
            account: account,
            credentialKey: key,
            inventory: inventory,
            capabilities: capabilities
        )
    }

    public func rebindEstablishedSession(
        _ session: GitHubConnectionSession,
        from sourceConnection: GitHubConnection,
        to targetConnection: GitHubConnection
    ) async throws -> GitHubConnectionSession {
        guard try matchingEndpoint(
            sourceConnection,
            targetConnection
        ) else {
            throw GitHubConnectionSessionError.connectionEndpointMismatch
        }
        try validateInventoryIdentity(
            session.inventory,
            expectedID: session.account.identity.id
        )

        let sourceKey = credentialKey(
            connection: sourceConnection,
            identity: session.account.identity
        )
        guard sourceKey == session.credentialKey,
              let initialCredential = try await credentialStore.load(
                  for: sourceKey
              )
        else {
            throw GitHubConnectionSessionError.credentialNotFound
        }
        try validateCredentialEndpointBinding(
            initialCredential,
            connection: sourceConnection
        )

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

        try Task.checkCancellation()
        let mutationKeys: Set<GitHubCredentialKey> = [
            sourceKey,
            targetKey,
        ]
        await acquireCredentialMutation(for: mutationKeys)
        defer {
            releaseCredentialMutation(for: mutationKeys)
        }
        try Task.checkCancellation()

        await cancelAndDrainRefreshTask(for: sourceKey)
        await cancelAndDrainRefreshTask(for: targetKey)
        try Task.checkCancellation()

        guard let credential = try await credentialStore.load(for: sourceKey) else {
            throw GitHubConnectionSessionError.credentialNotFound
        }
        try validateCredentialEndpointBinding(
            credential,
            connection: sourceConnection
        )
        let previousTargetCredential = try await credentialStore.load(
            for: targetKey
        )
        try Task.checkCancellation()

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
        } catch let error as GitHubAccessClientError where error.statusCode == 401 {
            throw GitHubConnectionSessionError.reauthenticationRequired
        } catch let error as GitHubAccessClientError
            where isSSORequired(error)
        {
            throw GitHubConnectionSessionError.ssoRequired
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
        } catch let error as GitHubAccessClientError where error.statusCode == 401 {
            throw GitHubConnectionSessionError.reauthenticationRequired
        } catch let error as GitHubAccessClientError
            where isSSORequired(error)
        {
            throw GitHubConnectionSessionError.ssoRequired
        }

        try validateInventoryIdentity(
            inventory,
            expectedID: account.identity.id
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
    }

    public func disconnect(
        connection: GitHubConnection,
        identity: GitHubAccountIdentity
    ) async throws {
        let key = credentialKey(connection: connection, identity: identity)
        let mutationKeys: Set<GitHubCredentialKey> = [key]
        await acquireCredentialMutation(for: mutationKeys)
        defer {
            releaseCredentialMutation(for: mutationKeys)
        }
        await cancelAndDrainRefreshTask(for: key)
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
        let key = credentialKey(
            connection: connection,
            identity: identity
        )
        let retryableFailedFlightID = refreshTasks[key].flatMap {
            $0.failureObserved ? $0.id : nil
        }

        while true {
            await waitForCredentialMutation(for: key)
            try Task.checkCancellation()
            let mutationGeneration = credentialMutationGeneration(
                for: key
            )

            var retryingFailedFlightID: UInt64?
            if let refreshFlight = refreshTasks[key] {
                if refreshFlight.id == retryableFailedFlightID,
                   refreshFlight.failureObserved
                {
                    retryingFailedFlightID = refreshFlight.id
                } else {
                    do {
                        let refreshed = try await refreshFlight.task.value
                        clearRefreshFlightIfOwned(
                            for: key,
                            id: refreshFlight.id
                        )
                        guard credentialMutationGeneration(
                            for: key
                        ) == mutationGeneration,
                        !credentialMutationKeys.contains(key)
                        else {
                            continue
                        }
                        try validateCredentialEndpointBinding(
                            refreshed,
                            connection: connection
                        )
                        return refreshed
                    } catch {
                        markRefreshFlightFailureIfOwned(
                            for: key,
                            id: refreshFlight.id
                        )
                        if credentialMutationGeneration(
                            for: key
                        ) != mutationGeneration
                            || credentialMutationKeys.contains(key)
                        {
                            try Task.checkCancellation()
                            continue
                        }
                        throw error
                    }
                }
            }

            let observedRefreshGeneration = refreshGeneration(
                for: key
            )
            guard let credential = try await credentialStore.load(
                for: key
            ) else {
                guard credentialMutationGeneration(
                    for: key
                ) == mutationGeneration,
                !credentialMutationKeys.contains(key),
                refreshGeneration(for: key)
                    == observedRefreshGeneration
                else {
                    continue
                }

                if let retryingFailedFlightID {
                    clearRefreshFlightIfOwned(
                        for: key,
                        id: retryingFailedFlightID
                    )
                }
                throw GitHubConnectionSessionError.credentialNotFound
            }

            guard credentialMutationGeneration(
                for: key
            ) == mutationGeneration,
            !credentialMutationKeys.contains(key),
            refreshGeneration(for: key)
                == observedRefreshGeneration
            else {
                continue
            }

            if let retryingFailedFlightID {
                guard refreshTasks[key]?.id
                    == retryingFailedFlightID
                else {
                    continue
                }
            } else if refreshTasks[key] != nil {
                continue
            }

            try validateCredentialEndpointBinding(
                credential,
                connection: connection
            )

            guard shouldRefresh(credential) else {
                if let retryingFailedFlightID {
                    clearRefreshFlightIfOwned(
                        for: key,
                        id: retryingFailedFlightID
                    )
                }
                return credential
            }

            guard let clientID,
                  let refreshToken = credential.refreshToken,
                  !refreshToken.isEmpty,
                  refreshTokenIsUsable(credential)
            else {
                if let retryingFailedFlightID {
                    clearRefreshFlightIfOwned(
                        for: key,
                        id: retryingFailedFlightID
                    )
                }
                throw GitHubConnectionSessionError
                    .reauthenticationRequired
            }

            let deviceFlowClient = self.deviceFlowClient
            let credentialStore = self.credentialStore
            let endpointIdentity = try canonicalEndpointIdentity(
                for: connection
            )
            let refreshID = nextRefreshSequence
            nextRefreshSequence &+= 1
            let refreshGeneration = observedRefreshGeneration &+ 1
            refreshGenerationByKey[key] = refreshGeneration

            let refreshTask = Task<GitHubCredential, Error> {
                let refreshed = try await deviceFlowClient.refresh(
                    connection: connection,
                    clientID: clientID,
                    credential: credential
                )
                let persistedCredential = Self.boundCredential(
                    refreshed,
                    endpointIdentity: endpointIdentity
                )
                try await credentialStore.save(
                    persistedCredential,
                    for: key
                )
                return persistedCredential
            }
            refreshTasks[key] = RefreshFlight(
                id: refreshID,
                generation: refreshGeneration,
                task: refreshTask,
                failureObserved: false
            )
        }
    }

    private func validateInventoryIdentity(
        _ inventory: GitHubAccessInventory,
        expectedID: String
    ) throws {
        let actualID = inventory.account.identity.id
        guard actualID == expectedID else {
            throw GitHubConnectionSessionError.accountMismatch(
                expectedID: expectedID,
                actualID: actualID
            )
        }
    }

    private func validateCredentialEndpointBinding(
        _ credential: GitHubCredential,
        connection: GitHubConnection
    ) throws {
        let expected = try canonicalEndpointIdentity(
            for: connection
        )

        if let actual = credential.endpointIdentity {
            guard actual == expected else {
                throw GitHubConnectionSessionError
                    .reauthenticationRequired
            }
            return
        }

        // Legacy credentials predate endpoint binding. Hosted GitHub endpoints
        // remain provider-controlled by the resolver, but arbitrary GHES hosts
        // must reauthenticate once so a tampered profile cannot redirect a
        // previously stored bearer credential.
        if connection.deploymentKind == .enterpriseServer {
            throw GitHubConnectionSessionError
                .reauthenticationRequired
        }
    }

    private func boundCredential(
        _ credential: GitHubCredential,
        to connection: GitHubConnection
    ) throws -> GitHubCredential {
        Self.boundCredential(
            credential,
            endpointIdentity: try canonicalEndpointIdentity(
                for: connection
            )
        )
    }

    private static func boundCredential(
        _ credential: GitHubCredential,
        endpointIdentity: String
    ) -> GitHubCredential {
        GitHubCredential(
            accessToken: credential.accessToken,
            refreshToken: credential.refreshToken,
            accessTokenExpiresAt: credential.accessTokenExpiresAt,
            refreshTokenExpiresAt: credential.refreshTokenExpiresAt,
            endpointIdentity: endpointIdentity
        )
    }

    private func canonicalEndpointIdentity(
        for connection: GitHubConnection
    ) throws -> String {
        try GitHubEndpointResolver.resolve(
            deploymentKind: connection.deploymentKind,
            webBaseURL: connection.webBaseURL
        ).webBaseURL.absoluteString
    }

    private func isSSORequired(
        _ error: GitHubAccessClientError
    ) -> Bool {
        guard case let .httpFailure(evidence) = error else {
            return false
        }
        return evidence.statusCode == 403
            && evidence.ssoSignal == .required
    }

    private func acquireCredentialMutation(
        for keys: Set<GitHubCredentialKey>
    ) async {
        while !credentialMutationKeys.isDisjoint(with: keys) {
            await withCheckedContinuation { continuation in
                credentialMutationWaiters.append(continuation)
            }
        }

        for key in keys {
            credentialMutationKeys.insert(key)
            credentialMutationGenerationByKey[key] =
                credentialMutationGeneration(for: key) &+ 1
        }
    }

    private func releaseCredentialMutation(
        for keys: Set<GitHubCredentialKey>
    ) {
        credentialMutationKeys.subtract(keys)
        let waiters = credentialMutationWaiters
        credentialMutationWaiters.removeAll()
        for waiter in waiters {
            waiter.resume()
        }
    }

    private func waitForCredentialMutation(
        for key: GitHubCredentialKey
    ) async {
        while credentialMutationKeys.contains(key) {
            await withCheckedContinuation { continuation in
                credentialMutationWaiters.append(continuation)
            }
        }
    }

    private func credentialMutationGeneration(
        for key: GitHubCredentialKey
    ) -> UInt64 {
        credentialMutationGenerationByKey[key] ?? 0
    }

    private func refreshGeneration(
        for key: GitHubCredentialKey
    ) -> UInt64 {
        refreshGenerationByKey[key] ?? 0
    }

    private func markRefreshFlightFailureIfOwned(
        for key: GitHubCredentialKey,
        id: UInt64
    ) {
        guard var refreshFlight = refreshTasks[key],
              refreshFlight.id == id
        else {
            return
        }
        refreshFlight.failureObserved = true
        refreshTasks[key] = refreshFlight
    }

    private func clearRefreshFlightIfOwned(
        for key: GitHubCredentialKey,
        id: UInt64
    ) {
        guard refreshTasks[key]?.id == id else {
            return
        }
        refreshTasks.removeValue(forKey: key)
    }

    private func cancelAndDrainRefreshTask(
        for key: GitHubCredentialKey
    ) async {
        guard let refreshFlight = refreshTasks.removeValue(
            forKey: key
        ) else {
            return
        }
        refreshFlight.task.cancel()
        _ = try? await refreshFlight.task.value
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

    private func matchingEndpoint(
        _ lhs: GitHubConnection,
        _ rhs: GitHubConnection
    ) throws -> Bool {
        guard lhs.deploymentKind == rhs.deploymentKind else {
            return false
        }

        let lhsEndpoint = try GitHubEndpointResolver.resolve(
            deploymentKind: lhs.deploymentKind,
            webBaseURL: lhs.webBaseURL
        ).webBaseURL
        let rhsEndpoint = try GitHubEndpointResolver.resolve(
            deploymentKind: rhs.deploymentKind,
            webBaseURL: rhs.webBaseURL
        ).webBaseURL

        return lhsEndpoint == rhsEndpoint
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

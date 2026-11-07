import Foundation
import SchneeBarGitHub
import Security

public enum DataProtectionGitHubCredentialStoreError: Error, Equatable, Sendable {
    case invalidEnrollmentPhase
    case invalidCredentialBinding
}

/// The binding check is pure so CI exercises it even without a signed,
/// interactive macOS Keychain. It is a necessary precondition, not proof that
/// the GitHub account, App installation or journal generation is current.
enum DataProtectionGitHubCredentialInsertPolicy {
    static func validate(
        credential: GitHubCredential,
        enrollment: GitHubCredentialEnrollmentLifecycle
    ) throws {
        guard enrollment.phase == .prepared || enrollment.phase == .migrationPrepared else {
            throw DataProtectionGitHubCredentialStoreError.invalidEnrollmentPhase
        }
        guard enrollment.generation > 0,
              credential.endpointIdentity == enrollment.canonicalWebOrigin,
              GitHubDeviceFlowResponsePolicy.isValidOpaqueToken(credential.accessToken),
              credential.refreshToken.map(GitHubDeviceFlowResponsePolicy.isValidOpaqueToken) ?? true
        else {
            throw DataProtectionGitHubCredentialStoreError.invalidCredentialBinding
        }
    }
}

/// A separate, opt-in storage boundary for credentials enrolled by a future
/// V2 authorization flow. This type is intentionally NOT a GitHubCredentialStore:
/// existing sessions continue using the unchanged legacy Keychain store.
///
/// Its add-only API avoids replacing an earlier enrollment accidentally.
/// Refresh rotation, migration, coordinated deletion and on-disk generation
/// fencing must be implemented and tested before the app adopts this store.
public actor DataProtectionGitHubCredentialStore {
    private let service: String

    public init(
        service: String = "dev.lamy.schneebar.github-credentials.v2"
    ) {
        self.service = service
    }

    public func load(
        for key: GitHubCredentialEnrollmentKey
    ) async throws -> GitHubCredential? {
        var query = DataProtectionGitHubCredentialQuery.baseQuery(
            service: service,
            key: key
        )
        query[kSecReturnData] = true
        query[kSecMatchLimit] = kSecMatchLimitOne

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        switch status {
        case errSecSuccess:
            guard let data = result as? Data else {
                throw GitHubKeychainError.invalidItemData
            }
            return try JSONDecoder().decode(GitHubCredential.self, from: data)
        case errSecItemNotFound:
            return nil
        default:
            throw GitHubKeychainError.unexpectedStatus(status)
        }
    }

    /// Insert a new enrollment once. An existing item is not overwritten:
    /// any token rotation must go through a separately reviewed coordinator.
    public func insert(
        _ credential: GitHubCredential,
        for enrollment: GitHubCredentialEnrollmentLifecycle
    ) async throws {
        // Never expose a raw-key insertion that could accidentally stage a
        // GitHub.com token into another enrollment's endpoint or purpose.
        // A future coordinator MUST additionally validate persisted journal
        // generation and the provider's numeric account identity before I/O.
        try DataProtectionGitHubCredentialInsertPolicy.validate(
            credential: credential,
            enrollment: enrollment
        )
        let data = try JSONEncoder().encode(credential)
        var query = DataProtectionGitHubCredentialQuery.baseQuery(
            service: service,
            key: enrollment.key
        )
        query[kSecValueData] = data
        query[kSecAttrAccessible] =
            kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly

        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw GitHubKeychainError.unexpectedStatus(status)
        }
    }

    /// Delete only this enrollment's exact V2 address. This is not a
    /// substitute for a durable disconnect tombstone or cleanup ledger.
    public func delete(
        for key: GitHubCredentialEnrollmentKey
    ) async throws {
        let query = DataProtectionGitHubCredentialQuery.baseQuery(
            service: service,
            key: key
        )
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw GitHubKeychainError.unexpectedStatus(status)
        }
    }
}

/// Shared exact-address query for lookup, insert and delete. Do not remove
/// kSecUseDataProtectionKeychain on legacy queries or broaden account matching.
/// The separate legacy store deliberately retains its original query behavior.
enum DataProtectionGitHubCredentialQuery {
    static func baseQuery(
        service: String,
        key: GitHubCredentialEnrollmentKey
    ) -> [CFString: Any] {
        [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: key.storageAccount,
            kSecAttrSynchronizable: kCFBooleanFalse as Any,
            kSecUseDataProtectionKeychain: kCFBooleanTrue as Any,
        ]
    }
}

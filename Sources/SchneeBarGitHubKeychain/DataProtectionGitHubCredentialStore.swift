import Foundation
import SchneeBarGitHub
import Security

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
        for key: GitHubCredentialEnrollmentKey
    ) async throws {
        let data = try JSONEncoder().encode(credential)
        var query = DataProtectionGitHubCredentialQuery.baseQuery(
            service: service,
            key: key
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

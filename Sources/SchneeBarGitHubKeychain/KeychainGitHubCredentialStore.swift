import Foundation
import SchneeBarGitHub
import Security

public enum GitHubKeychainError: Error, Equatable, Sendable {
    case unexpectedStatus(OSStatus)
    case invalidItemData
}

public actor KeychainGitHubCredentialStore: GitHubCredentialStore {
    private let service: String

    public init(service: String = "dev.lamy.schneebar.github-credentials") {
        self.service = service
    }

    public func load(for key: GitHubCredentialKey) async throws -> GitHubCredential? {
        var query = baseQuery(for: key)
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

    public func save(
        _ credential: GitHubCredential,
        for key: GitHubCredentialKey
    ) async throws {
        let data = try JSONEncoder().encode(credential)
        let query = baseQuery(for: key)
        let attributes: [CFString: Any] = [
            kSecValueData: data,
        ]

        let updateStatus = SecItemUpdate(
            query as CFDictionary,
            attributes as CFDictionary
        )

        if updateStatus == errSecSuccess {
            return
        }
        guard updateStatus == errSecItemNotFound else {
            throw GitHubKeychainError.unexpectedStatus(updateStatus)
        }

        var item = query
        item[kSecValueData] = data
        item[kSecAttrAccessible] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        item[kSecAttrSynchronizable] = kCFBooleanFalse

        let addStatus = SecItemAdd(item as CFDictionary, nil)
        guard addStatus == errSecSuccess else {
            throw GitHubKeychainError.unexpectedStatus(addStatus)
        }
    }

    public func delete(for key: GitHubCredentialKey) async throws {
        let status = SecItemDelete(baseQuery(for: key) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw GitHubKeychainError.unexpectedStatus(status)
        }
    }

    private func baseQuery(for key: GitHubCredentialKey) -> [CFString: Any] {
        [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: key.storageAccount,
        ]
    }
}

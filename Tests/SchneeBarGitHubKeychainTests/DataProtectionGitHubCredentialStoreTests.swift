import Foundation
import SchneeBarGitHub
@testable import SchneeBarGitHubKeychain
import Security
import Testing

@Test
func enrollmentStorageKeyIsNewAndScopedToConsentAndPurpose() {
    let a = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
    let b = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
    let readA = GitHubCredentialEnrollmentKey(enrollmentID: a, purpose: .read)
    let readB = GitHubCredentialEnrollmentKey(enrollmentID: b, purpose: .read)
    let writeA = GitHubCredentialEnrollmentKey(enrollmentID: a, purpose: .write)
    let legacy = GitHubCredentialKey(connectionID: a, accountID: "123456")

    #expect(readA.storageAccount == "v2:read:00000000-0000-0000-0000-000000000001")
    #expect(readA.storageAccount != readB.storageAccount)
    #expect(readA.storageAccount != writeA.storageAccount)
    #expect(readA.storageAccount != legacy.storageAccount)
    #expect(readA == GitHubCredentialEnrollmentKey(enrollmentID: a, purpose: .read))
}

@Test
func dataProtectionQueryKeepsExactEnrollmentAndNoSynchronizing() {
    let key = GitHubCredentialEnrollmentKey(
        enrollmentID: UUID(uuidString: "00000000-0000-0000-0000-000000000042")!,
        purpose: .read
    )
    let query = DataProtectionGitHubCredentialQuery.baseQuery(
        service: "dev.lamy.schneebar.tests.dpk.v2",
        key: key
    )

    #expect(query[kSecClass] as? String == kSecClassGenericPassword as String)
    #expect(query[kSecAttrService] as? String ==
        "dev.lamy.schneebar.tests.dpk.v2")
    #expect(query[kSecAttrAccount] as? String == key.storageAccount)
    #expect((query[kSecUseDataProtectionKeychain] as? Bool) == true)
    #expect((query[kSecAttrSynchronizable] as? Bool) == false)
    #expect(query[kSecAttrAccessGroup] == nil)
    #expect(query[kSecMatchLimit] == nil)
}

@Test
func dataProtectionWriteQueryCannotMatchLegacyAccountByAccident() {
    let connectionID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
    let legacy = GitHubCredentialKey(connectionID: connectionID, accountID: "100")
    let v2 = GitHubCredentialEnrollmentKey(
        enrollmentID: connectionID,
        purpose: .write
    )
    let query = DataProtectionGitHubCredentialQuery.baseQuery(
        service: "dev.lamy.schneebar.github-credentials.v2",
        key: v2
    )

    #expect(query[kSecAttrAccount] as? String != legacy.storageAccount)
    #expect(query[kSecAttrService] as? String !=
        "dev.lamy.schneebar.github-credentials")
}

/// Optional real-Mac smoke test. Run only with a signed interactive host
/// and an intentionally provided environment opt-in; CI alone cannot prove
/// Keychain accessibility across lock/first-unlock states.
@Test
func signedMacDataProtectionKeychainSmokeWhenExplicitlyEnabled() async throws {
    guard ProcessInfo.processInfo.environment["SCHNEEBAR_DPK_REAL_MAC_SMOKE"] == "1"
    else {
        return
    }

    let store = DataProtectionGitHubCredentialStore(
        service: "dev.lamy.schneebar.dpk-smoke.\(UUID().uuidString)"
    )
    let firstKey = GitHubCredentialEnrollmentKey(
        enrollmentID: UUID(),
        purpose: .read
    )
    let secondKey = GitHubCredentialEnrollmentKey(
        enrollmentID: UUID(),
        purpose: .read
    )
    let first = GitHubCredential(
        accessToken: "synthetic-smoke-token-a",
        endpointIdentity: "https://github.com"
    )
    let second = GitHubCredential(
        accessToken: "synthetic-smoke-token-b",
        endpointIdentity: "https://github.com"
    )
    var insertedKeys: [GitHubCredentialEnrollmentKey] = []

    do {
        #expect(try await store.load(for: firstKey) == nil)
        try await store.insert(first, for: firstKey)
        insertedKeys.append(firstKey)
        #expect(try await store.load(for: firstKey) == first)

        try await store.insert(second, for: secondKey)
        insertedKeys.append(secondKey)
        #expect(try await store.load(for: secondKey) == second)

        do {
            try await store.insert(first, for: firstKey)
            Issue.record("Existing V2 enrollment was unexpectedly overwritten")
        } catch GitHubKeychainError.unexpectedStatus(errSecDuplicateItem) {
            // Expected: one consent never silently replaces another.
        }

        try await store.delete(for: firstKey)
        insertedKeys.removeAll { $0 == firstKey }
        #expect(try await store.load(for: firstKey) == nil)
        #expect(try await store.load(for: secondKey) == second)
    } catch {
        // Clean up even after a failed live Keychain assertion.
        for key in insertedKeys {
            try? await store.delete(for: key)
        }
        throw error
    }

    for key in insertedKeys {
        try await store.delete(for: key)
        #expect(try await store.load(for: key) == nil)
    }
}

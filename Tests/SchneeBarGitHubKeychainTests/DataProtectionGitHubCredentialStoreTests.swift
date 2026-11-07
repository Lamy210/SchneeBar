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

/// Optional, REAL macOS/keychain test. It must run in a signed, interactive
/// host app with its own test service. Unsigned GitHub CI is not Keychain
/// protection or lock-state evidence. Enable it only with a dedicated host.
@Test
func signedMacDataProtectionKeychainSmokeWhenExplicitlyEnabled() async throws {
    guard ProcessInfo.processInfo.environment["SCHNEEBAR_DPK_REAL_MAC_SMOKE"] == "1"
    else {
        return
    }

    let store = DataProtectionGitHubCredentialStore(
        service: "dev.lamy.schneebar.dpk-smoke.\(UUID().uuidString)"
    )
    let key = GitHubCredentialEnrollmentKey(
        enrollmentID: UUID(),
        purpose: .read
    )
    let credential = GitHubCredential(
        accessToken: "synthetic-smoke-token",
        endpointIdentity: "https://github.com"
    )
    defer {
        // Never leave a real token here; this fixture stores synthetic data.
        // Asynchronous cleanup is performed below, not in this defer.
    }
    #expect(try await store.load(for: key) == nil)
    try await store.insert(credential, for: key)
    #expect(try await store.load(for: key) == credential)

    do {
        try await store.insert(credential, for: key)
        Issue.record("V2 insert unexpectedly overwrote the existing item")
    } catch GitHubKeychainError.unexpectedStatus(errSecDuplicateItem) {
        // Expected: existing enrollment cannot be overwritten.
    }

    try await store.delete(for: key)
    #expect(try await store.load(for: key) == nil)
}

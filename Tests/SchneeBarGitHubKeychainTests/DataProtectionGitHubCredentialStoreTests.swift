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
    let firstEnrollment = try identityBoundTestEnrollment(for: firstKey)
    let secondEnrollment = try identityBoundTestEnrollment(for: secondKey)
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
        try await store.insert(first, for: firstEnrollment)
        insertedKeys.append(firstKey)
        #expect(try await store.load(for: firstKey) == first)

        try await store.insert(second, for: secondEnrollment)
        insertedKeys.append(secondKey)
        #expect(try await store.load(for: secondKey) == second)

        do {
            try await store.insert(first, for: firstEnrollment)
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


private func identityBoundTestEnrollment(
    for key: GitHubCredentialEnrollmentKey,
    origin: String = "https://github.com"
) throws -> GitHubCredentialEnrollmentLifecycle {
    try GitHubCredentialEnrollmentLifecycle(
        enrollmentID: key.enrollmentID,
        purpose: key.purpose,
        canonicalWebOrigin: origin,
        numericAccountID: "12345",
        appClientID: "Iv1.synthetic-testing"
    )
}

@Test
func v2InsertionRequiresExactCanonicalEndpointBinding() throws {
    let key = GitHubCredentialEnrollmentKey(enrollmentID: UUID(), purpose: .read)
    let enrollment = try identityBoundTestEnrollment(for: key)
    try DataProtectionGitHubCredentialInsertPolicy.validate(
        credential: GitHubCredential(
            accessToken: "ghu_test",
            endpointIdentity: "https://github.com"
        ),
        enrollment: enrollment
    )
    let untrustedOrigins: [String?] = [
        nil,
        "https://other.example",
        "https://github.com:8443",
        "https://github.com/other",
    ]
    for otherOrigin in untrustedOrigins {
        #expect(throws: DataProtectionGitHubCredentialStoreError.invalidCredentialBinding) {
            try DataProtectionGitHubCredentialInsertPolicy.validate(
                credential: GitHubCredential(
                    accessToken: "ghu_test",
                    endpointIdentity: otherOrigin
                ),
                enrollment: enrollment
            )
        }
    }
}

@Test
func v2InsertionRejectsStalePhaseAndInvalidOpaqueTokens() throws {
    let key = GitHubCredentialEnrollmentKey(enrollmentID: UUID(), purpose: .write)
    let prepared = try identityBoundTestEnrollment(for: key)
    let active = try prepared.transitioned(to: .dpActive, expectedGeneration: 1)
    #expect(throws: DataProtectionGitHubCredentialStoreError.invalidEnrollmentPhase) {
        try DataProtectionGitHubCredentialInsertPolicy.validate(
            credential: GitHubCredential(
                accessToken: "ghu_test",
                endpointIdentity: "https://github.com"
            ),
            enrollment: active
        )
    }
    for token in [
        "",
        String(
            repeating: "a",
            count: GitHubDeviceFlowResponsePolicy.maximumOpaqueTokenCharacters + 1
        ),
    ] {
        #expect(throws: DataProtectionGitHubCredentialStoreError.invalidCredentialBinding) {
            try DataProtectionGitHubCredentialInsertPolicy.validate(
                credential: GitHubCredential(
                    accessToken: token,
                    endpointIdentity: "https://github.com"
                ),
                enrollment: prepared
            )
        }
    }
    #expect(throws: DataProtectionGitHubCredentialStoreError.invalidCredentialBinding) {
        try DataProtectionGitHubCredentialInsertPolicy.validate(
            credential: GitHubCredential(
                accessToken: "ghu_test",
                refreshToken: "",
                endpointIdentity: "https://github.com"
            ),
            enrollment: prepared
        )
    }
}

@Test
func v2InsertionSupportsExactlyMatchedCustomGHESOrigin() throws {
    let key = GitHubCredentialEnrollmentKey(enrollmentID: UUID(), purpose: .read)
    let enrollment = try identityBoundTestEnrollment(
        for: key,
        origin: "https://github.internal.example:8443"
    )
    try DataProtectionGitHubCredentialInsertPolicy.validate(
        credential: GitHubCredential(
            accessToken: "ghu_enterprise",
            endpointIdentity: "https://github.internal.example:8443"
        ),
        enrollment: enrollment
    )
    #expect(throws: DataProtectionGitHubCredentialStoreError.invalidCredentialBinding) {
        try DataProtectionGitHubCredentialInsertPolicy.validate(
            credential: GitHubCredential(
                accessToken: "ghu_enterprise",
                endpointIdentity: "https://github.internal.example"
            ),
            enrollment: enrollment
        )
    }
}


@Test
func dataProtectionActiveReadRequiresDpActivePhase() throws {
    let prepared = try identityBoundTestEnrollment(
        for: GitHubCredentialEnrollmentKey(enrollmentID: UUID(), purpose: .read)
    )
    let active = try prepared.transitioned(to: .dpActive, expectedGeneration: 1)
    let valid = GitHubCredential(
        accessToken: "synthetic-read-token",
        endpointIdentity: "https://github.com"
    )
    try DataProtectionGitHubCredentialReadPolicy.validate(
        credential: valid, enrollment: active
    )

    let denied = [
        prepared,
        try prepared.transitioned(to: .reauthRequired, expectedGeneration: 1),
        try prepared.transitioned(to: .disconnected, expectedGeneration: 1),
        try active.transitioned(to: .refreshInFlight, expectedGeneration: 2),
    ]
    for enrollment in denied {
        #expect(throws: DataProtectionGitHubCredentialStoreError.inactiveEnrollment) {
            try DataProtectionGitHubCredentialReadPolicy.validate(
                credential: valid, enrollment: enrollment
            )
        }
    }

    let legacy = try GitHubCredentialEnrollmentLifecycle.prepareVerifiedLegacy(
        enrollmentID: UUID(),
        purpose: .read,
        canonicalWebOrigin: "https://github.com",
        numericAccountID: "12345",
        appClientID: "Iv1.synthetic-testing"
    )
    let migrating = try legacy.transitioned(to: .migrationPrepared, expectedGeneration: 1)
    #expect(throws: DataProtectionGitHubCredentialStoreError.inactiveEnrollment) {
        try DataProtectionGitHubCredentialReadPolicy.validate(
            credential: valid, enrollment: migrating
        )
    }
}

@Test
func dataProtectionActiveReadRejectsWrongOrUnboundEndpoint() throws {
    let prepared = try identityBoundTestEnrollment(
        for: GitHubCredentialEnrollmentKey(enrollmentID: UUID(), purpose: .write)
    )
    let active = try prepared.transitioned(to: .dpActive, expectedGeneration: 1)
    for endpoint: String? in [
        nil, "https://other.example", "https://github.com:8443",
        "https://github.com/path", "http://github.com"
    ] {
        #expect(throws: DataProtectionGitHubCredentialStoreError.invalidCredentialBinding) {
            try DataProtectionGitHubCredentialReadPolicy.validate(
                credential: GitHubCredential(
                    accessToken: "synthetic-token", endpointIdentity: endpoint
                ),
                enrollment: active
            )
        }
    }
}

@Test
func dataProtectionActiveReadRejectsMalformedOpaqueTokens() throws {
    let prepared = try identityBoundTestEnrollment(
        for: GitHubCredentialEnrollmentKey(enrollmentID: UUID(), purpose: .read)
    )
    let active = try prepared.transitioned(to: .dpActive, expectedGeneration: 1)
    let oversized = String(
        repeating: "x",
        count: GitHubDeviceFlowResponsePolicy.maximumOpaqueTokenCharacters + 1
    )
    for badAccess in ["", oversized] {
        #expect(throws: DataProtectionGitHubCredentialStoreError.invalidCredentialBinding) {
            try DataProtectionGitHubCredentialReadPolicy.validate(
                credential: GitHubCredential(
                    accessToken: badAccess, endpointIdentity: "https://github.com"
                ),
                enrollment: active
            )
        }
    }
    for badRefresh in ["", oversized] {
        #expect(throws: DataProtectionGitHubCredentialStoreError.invalidCredentialBinding) {
            try DataProtectionGitHubCredentialReadPolicy.validate(
                credential: GitHubCredential(
                    accessToken: "synthetic-access",
                    refreshToken: badRefresh,
                    endpointIdentity: "https://github.com"
                ),
                enrollment: active
            )
        }
    }
}

@Test
func dataProtectionActiveReadRetainsExactGHESOriginAndLegacyLifetimeCompatibility() throws {
    let origin = "https://github.internal.example:8443"
    let prepared = try identityBoundTestEnrollment(
        for: GitHubCredentialEnrollmentKey(enrollmentID: UUID(), purpose: .read),
        origin: origin
    )
    let active = try prepared.transitioned(to: .dpActive, expectedGeneration: 1)
    let valid = GitHubCredential(
        accessToken: "synthetic-ghes-access",
        endpointIdentity: origin
    )
    try DataProtectionGitHubCredentialReadPolicy.validate(
        credential: valid, enrollment: active
    )
    #expect(throws: DataProtectionGitHubCredentialStoreError.invalidCredentialBinding) {
        try DataProtectionGitHubCredentialReadPolicy.validate(
            credential: GitHubCredential(
                accessToken: "synthetic-ghes-access",
                endpointIdentity: "https://github.internal.example"
            ),
            enrollment: active
        )
    }
}

@Test
func dataProtectionLoadActiveRefusesStagedEnrollmentBeforeKeychainQuery() async throws {
    let prepared = try identityBoundTestEnrollment(
        for: GitHubCredentialEnrollmentKey(enrollmentID: UUID(), purpose: .read)
    )
    let store = DataProtectionGitHubCredentialStore(
        service: "dev.lamy.schneebar.tests.nonexistent"
    )
    await #expect(throws: DataProtectionGitHubCredentialStoreError.inactiveEnrollment) {
        try await store.loadActive(for: prepared)
    }
}


@Test
func dataProtectionActiveReadRejectsForgedDecodedEnrollmentIdentity() throws {
    let prepared = try identityBoundTestEnrollment(
        for: GitHubCredentialEnrollmentKey(enrollmentID: UUID(), purpose: .read)
    )
    let active = try prepared.transitioned(to: .dpActive, expectedGeneration: 1)
    let original = try #require(
        JSONSerialization.jsonObject(with: JSONEncoder().encode(active)) as? [String: Any]
    )
    for (field, invalid): (String, String) in [
        ("canonicalWebOrigin", "http://github.com"),
        ("numericAccountID", "not-a-numeric-account"),
        ("appClientID", "")
    ] {
        var document = original
        document[field] = invalid
        let forged = try JSONDecoder().decode(
            GitHubCredentialEnrollmentLifecycle.self,
            from: JSONSerialization.data(withJSONObject: document)
        )
        #expect(throws: DataProtectionGitHubCredentialStoreError.invalidEnrollmentIdentity) {
            try DataProtectionGitHubCredentialReadPolicy.validateActiveEnrollment(forged)
        }
    }

    var impossibleGeneration = original
    impossibleGeneration["generation"] = 1
    let forged = try JSONDecoder().decode(
        GitHubCredentialEnrollmentLifecycle.self,
        from: JSONSerialization.data(withJSONObject: impossibleGeneration)
    )
    #expect(throws: DataProtectionGitHubCredentialStoreError.inactiveEnrollment) {
        try DataProtectionGitHubCredentialReadPolicy.validateActiveEnrollment(forged)
    }
}

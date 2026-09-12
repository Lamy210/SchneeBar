import Foundation
import SchneeBarGitHub
import SchneeBarGitHubKeychain
import Testing

@Test
func keychainCredentialStoreRoundTripsUpdatesAndDeletesCredential() async throws {
    let service = "dev.lamy.schneebar.tests.github.\(UUID().uuidString)"
    let store = KeychainGitHubCredentialStore(service: service)
    let key = GitHubCredentialKey(
        connectionID: UUID(),
        accountID: "123456"
    )

    let missing = try await store.load(for: key)
    #expect(missing == nil)

    let first = GitHubCredential(
        accessToken: "test-access-token-1",
        refreshToken: "test-refresh-token-1",
        accessTokenExpiresAt: Date(timeIntervalSince1970: 1_000),
        refreshTokenExpiresAt: Date(timeIntervalSince1970: 2_000)
    )
    try await store.save(first, for: key)
    #expect(try await store.load(for: key) == first)

    let updated = GitHubCredential(
        accessToken: "test-access-token-2",
        refreshToken: "test-refresh-token-2",
        accessTokenExpiresAt: Date(timeIntervalSince1970: 3_000),
        refreshTokenExpiresAt: Date(timeIntervalSince1970: 4_000)
    )
    try await store.save(updated, for: key)
    #expect(try await store.load(for: key) == updated)

    try await store.delete(for: key)
    #expect(try await store.load(for: key) == nil)
}

@Test
func credentialStorageAccountSeparatesConnectionAndGitHubAccount() {
    let connectionID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!

    let first = GitHubCredentialKey(connectionID: connectionID, accountID: "100")
    let second = GitHubCredentialKey(connectionID: connectionID, accountID: "200")

    #expect(first.storageAccount != second.storageAccount)
    #expect(first.storageAccount.contains("00000000-0000-0000-0000-000000000001"))
}

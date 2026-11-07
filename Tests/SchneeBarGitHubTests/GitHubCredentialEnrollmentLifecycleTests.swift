import Foundation
import Testing
@testable import SchneeBarGitHub

private func newEnrollment(
    id: UUID = UUID(),
    purpose: GitHubCredentialAuthorizationPurpose = .read
) throws -> GitHubCredentialEnrollmentLifecycle {
    try GitHubCredentialEnrollmentLifecycle(
        enrollmentID: id,
        purpose: purpose,
        canonicalWebOrigin: "https://github.com",
        numericAccountID: "12345",
        appClientID: "Iv1.testing-client"
    )
}

@Test
func lifecycleUsesMonotonicGenerationsAndRejectsStaleCompletions() throws {
    let created = try newEnrollment()
    #expect(created.phase == .prepared)
    #expect(created.generation == 1)
    let active = try created.transitioned(to: .dpActive, expectedGeneration: 1)
    #expect(active.phase == .dpActive)
    #expect(active.generation == 2)
    #expect(created.phase == .prepared)
    #expect(throws: GitHubCredentialEnrollmentTransitionError.staleGeneration) {
        try active.transitioned(to: .refreshInFlight, expectedGeneration: 1)
    }
    let refreshing = try active.transitioned(to: .refreshInFlight, expectedGeneration: 2)
    let disconnected = try refreshing.transitioned(to: .disconnected, expectedGeneration: 3)
    #expect(disconnected.phase == .disconnected)
    #expect(disconnected.generation == 4)
    #expect(throws: GitHubCredentialEnrollmentTransitionError.invalidTransition) {
        try disconnected.transitioned(to: .dpActive, expectedGeneration: 4)
    }
}

@Test
func oldDisconnectCannotAuthorizeDeletingReconnectedEnrollment() throws {
    let old = try newEnrollment(id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!)
    let newer = try newEnrollment(id: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!)
    #expect(old.key.storageAccount != newer.key.storageAccount)
    let oldDisconnected = try old.transitioned(to: .disconnected, expectedGeneration: 1)
    let scope = try #require(oldDisconnected.disconnectedCleanupScope)
    #expect(oldDisconnected.matchesDisconnectedCleanup(scope))
    #expect(!newer.matchesDisconnectedCleanup(scope))
    #expect(newer.disconnectedCleanupScope == nil)
    let otherPhase = try newer.transitioned(to: .disconnected, expectedGeneration: 1)
    #expect(!otherPhase.matchesDisconnectedCleanup(scope))
}

@Test
func readWriteEnrollmentsAndEpochsAreNeverInterchangeable() throws {
    let id = UUID(uuidString: "00000000-0000-0000-0000-000000000003")!
    let read = try newEnrollment(id: id, purpose: .read)
    let write = try newEnrollment(id: id, purpose: .write)
    let readTombstone = try read.transitioned(to: .disconnected, expectedGeneration: 1)
    let writeTombstone = try write.transitioned(to: .disconnected, expectedGeneration: 1)
    let scope = try #require(readTombstone.disconnectedCleanupScope)
    #expect(readTombstone.matchesDisconnectedCleanup(scope))
    #expect(!writeTombstone.matchesDisconnectedCleanup(scope))
    #expect(read.key.storageAccount != write.key.storageAccount)
}

@Test
func lifecycleRequiresProviderIdentityAndRejectsUnsafeOrigin() throws {
    for origin in ["http://github.com", "https://user:pass@github.com", "https://github.com?x=1"] {
        #expect(throws: GitHubCredentialEnrollmentTransitionError.invalidIdentity) {
            try GitHubCredentialEnrollmentLifecycle(
                enrollmentID: UUID(), purpose: .read, canonicalWebOrigin: origin,
                numericAccountID: "123", appClientID: "Iv1.client"
            )
        }
    }
    #expect(throws: GitHubCredentialEnrollmentTransitionError.invalidIdentity) {
        try GitHubCredentialEnrollmentLifecycle(
            enrollmentID: UUID(), purpose: .read, canonicalWebOrigin: "https://github.com",
            numericAccountID: "000123", appClientID: "Iv1.client"
        )
    }
}

@Test
func legacyMigrationTransitionRequiresExpectedGeneration() throws {
    let old = try GitHubCredentialEnrollmentLifecycle.prepareVerifiedLegacy(
        enrollmentID: UUID(), purpose: .read, canonicalWebOrigin: "https://github.com",
        numericAccountID: "123", appClientID: "Iv1.legacy"
    )
    #expect(old.phase == .legacyActive)
    let staged = try old.transitioned(to: .migrationPrepared, expectedGeneration: 1)
    #expect(throws: GitHubCredentialEnrollmentTransitionError.staleGeneration) {
        try staged.transitioned(to: .dpActive, expectedGeneration: 1)
    }
    let promoted = try staged.transitioned(to: .dpActive, expectedGeneration: 2)
    #expect(promoted.phase == .dpActive)
}

@Test
func lifecycleMetadataSerializesWithoutCredentialSecrets() throws {
    let state = try newEnrollment()
    let data = try JSONEncoder().encode(state)
    let decoded = try JSONDecoder().decode(GitHubCredentialEnrollmentLifecycle.self, from: data)
    #expect(state == decoded)
    let text = try #require(String(data: data, encoding: .utf8))
    #expect(!text.contains("accessToken"))
    #expect(!text.contains("refreshToken"))
}

@Test
func enrollmentOriginMustNotIncludeAPreselectedPath() throws {
    for origin in ["https://github.com/private", "https://github.com/v1?x=1",
                   "https://github.com/#access"] {
        #expect(throws: GitHubCredentialEnrollmentTransitionError.invalidIdentity) {
            try GitHubCredentialEnrollmentLifecycle(
                enrollmentID: UUID(), purpose: .read,
                canonicalWebOrigin: origin, numericAccountID: "123",
                appClientID: "Iv1.client"
            )
        }
    }
}

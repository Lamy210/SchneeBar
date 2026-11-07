import Foundation
import Testing
@testable import SchneeBarGitHub

private enum MigrationFixtureError: Error, Equatable {
    case duplicate
}

private final class MigrationJournalMemory: GitHubCredentialEnrollmentJournalPersistence, @unchecked Sendable {
    private let lock = NSLock()
    private var records: [GitHubCredentialEnrollmentLifecycle] = []

    func load() throws -> [GitHubCredentialEnrollmentLifecycle] {
        lock.lock()
        defer { lock.unlock() }
        return records
    }

    func compareAndReplace(
        expected: [GitHubCredentialEnrollmentLifecycle],
        next: [GitHubCredentialEnrollmentLifecycle]
    ) throws {
        lock.lock()
        defer { lock.unlock() }
        guard records == expected else {
            throw GitHubCredentialEnrollmentJournalError.staleSnapshot
        }
        records = next
    }
}

private actor MigrationSyntheticLegacyStore: GitHubCredentialStore {
    private var entries: [GitHubCredentialKey: GitHubCredential]
    private var deletions = 0

    init(key: GitHubCredentialKey, credential: GitHubCredential?) {
        entries = credential.map { [key: $0] } ?? [:]
    }

    func load(for key: GitHubCredentialKey) async throws -> GitHubCredential? {
        entries[key]
    }

    func save(_ credential: GitHubCredential, for key: GitHubCredentialKey) async throws {
        entries[key] = credential
    }

    func delete(for key: GitHubCredentialKey) async throws {
        deletions += 1
        entries.removeValue(forKey: key)
    }

    func deletionCount() -> Int { deletions }
}

private actor MigrationSyntheticV2Store: GitHubCredentialEnrollmentStagingDestination {
    private var entries: [GitHubCredentialEnrollmentKey: GitHubCredential] = [:]
    private var corruptReadback = false
    private var onInsert: (@Sendable () async throws -> Void)?

    func seed(_ credential: GitHubCredential, for key: GitHubCredentialEnrollmentKey) {
        entries[key] = credential
    }

    func makeReadbackMismatched() {
        corruptReadback = true
    }

    func beforeInsert(_ callback: @escaping @Sendable () async throws -> Void) {
        onInsert = callback
    }

    func load(for key: GitHubCredentialEnrollmentKey) async throws -> GitHubCredential? {
        guard let saved = entries[key] else { return nil }
        if corruptReadback {
            return GitHubCredential(
                accessToken: "synthetic-altered-token",
                endpointIdentity: saved.endpointIdentity
            )
        }
        return saved
    }

    func insert(
        _ credential: GitHubCredential,
        for enrollment: GitHubCredentialEnrollmentLifecycle
    ) async throws {
        guard enrollment.phase == .migrationPrepared,
              enrollment.purpose == .read,
              credential.endpointIdentity == enrollment.canonicalWebOrigin,
              !credential.accessToken.isEmpty
        else {
            throw MigrationFixtureError.duplicate
        }
        if let callback = onInsert {
            try await callback()
        }
        guard entries[enrollment.key] == nil else {
            throw MigrationFixtureError.duplicate
        }
        entries[enrollment.key] = credential
    }
}

private struct MigrationTestContext {
    let lifecycle: GitHubCredentialEnrollmentLifecycle
    let journal: GitHubCredentialEnrollmentJournal
    let legacy: MigrationSyntheticLegacyStore
    let destination: MigrationSyntheticV2Store
    let oldKey: GitHubCredentialKey
    let binding: GitHubLegacyMigrationBinding
    let credential: GitHubCredential

    var stager: GitHubCredentialMigrationStager {
        GitHubCredentialMigrationStager(
            legacy: legacy,
            destination: destination,
            journal: journal
        )
    }
}

private func migrationContext(
    purpose: GitHubCredentialAuthorizationPurpose = .read,
    endpoint: String? = "https://github.com",
    hasLegacy: Bool = true
) async throws -> MigrationTestContext {
    let connectionID = UUID()
    let oldKey = GitHubCredentialKey(connectionID: connectionID, accountID: "123")
    let credential = GitHubCredential(
        accessToken: "synthetic-access-token",
        refreshToken: "synthetic-refresh-token",
        accessTokenExpiresAt: Date(timeIntervalSince1970: 1_000),
        refreshTokenExpiresAt: Date(timeIntervalSince1970: 2_000),
        endpointIdentity: endpoint
    )
    let record = try GitHubCredentialEnrollmentLifecycle.prepareVerifiedLegacy(
        enrollmentID: UUID(),
        purpose: purpose,
        canonicalWebOrigin: "https://github.com",
        numericAccountID: "123",
        appClientID: "Iv1.synthetic-client"
    )
    let journal = GitHubCredentialEnrollmentJournal(
        persistence: MigrationJournalMemory()
    )
    _ = try await journal.register(record)
    return MigrationTestContext(
        lifecycle: record,
        journal: journal,
        legacy: MigrationSyntheticLegacyStore(
            key: oldKey,
            credential: hasLegacy ? credential : nil
        ),
        destination: MigrationSyntheticV2Store(),
        oldKey: oldKey,
        binding: GitHubLegacyMigrationBinding(
            connectionID: connectionID,
            numericAccountID: "123",
            canonicalWebOrigin: "https://github.com",
            appClientID: "Iv1.synthetic-client"
        ),
        credential: credential
    )
}

@Test
func migrationStagingReadsBackFullV2AndNeverDeletesLegacy() async throws {
    let f = try await migrationContext()
    let done = try await f.stager.stageReadCredential(
        enrollmentID: f.lifecycle.enrollmentID,
        legacyKey: f.oldKey,
        binding: f.binding,
        expectedGeneration: 1
    )
    #expect(done.phase == .dpActive)
    #expect(done.generation == 3)
    #expect(try await f.destination.load(for: done.key) == f.credential)
    #expect(try await f.legacy.load(for: f.oldKey) == f.credential)
    #expect(await f.legacy.deletionCount() == 0)
}

@Test
func migrationPreparedWithAlreadyStagedMatchingV2CanResumeAfterRestart() async throws {
    let f = try await migrationContext()
    let prepared = try await f.journal.transition(
        enrollmentID: f.lifecycle.enrollmentID,
        expectedGeneration: 1,
        to: .migrationPrepared
    )
    await f.destination.seed(f.credential, for: prepared.key)
    let done = try await f.stager.stageReadCredential(
        enrollmentID: f.lifecycle.enrollmentID,
        legacyKey: f.oldKey,
        binding: f.binding,
        expectedGeneration: prepared.generation
    )
    #expect(done.phase == .dpActive)
    #expect(done.generation == 3)
    #expect(await f.legacy.deletionCount() == 0)
}

@Test
func migrationCannotOverwriteDifferentExistingV2Credential() async throws {
    let f = try await migrationContext()
    await f.destination.seed(
        GitHubCredential(accessToken: "foreign-token", endpointIdentity: "https://github.com"),
        for: f.lifecycle.key
    )
    await #expect(throws: GitHubCredentialMigrationStagingError.existingV2CredentialMismatch) {
        try await f.stager.stageReadCredential(
            enrollmentID: f.lifecycle.enrollmentID,
            legacyKey: f.oldKey, binding: f.binding, expectedGeneration: 1
        )
    }
    #expect(try await f.journal.record(for: f.lifecycle.enrollmentID)?.phase ==
        .migrationPrepared)
    #expect(try await f.legacy.load(for: f.oldKey) == f.credential)
    #expect(await f.legacy.deletionCount() == 0)
}

@Test
func migrationReadbackMismatchLeavesOldCredentialIntact() async throws {
    let f = try await migrationContext()
    await f.destination.makeReadbackMismatched()
    await #expect(throws: GitHubCredentialMigrationStagingError.v2ReadbackMismatch) {
        try await f.stager.stageReadCredential(
            enrollmentID: f.lifecycle.enrollmentID,
            legacyKey: f.oldKey, binding: f.binding, expectedGeneration: 1
        )
    }
    #expect(try await f.journal.record(for: f.lifecycle.enrollmentID)?.phase ==
        .migrationPrepared)
    #expect(try await f.legacy.load(for: f.oldKey) == f.credential)
}

@Test
func migrationRejectsUnboundLegacyEndpointBeforeV2Writes() async throws {
    let f = try await migrationContext(endpoint: nil)
    await #expect(throws: GitHubCredentialMigrationStagingError.endpointBindingUnverified) {
        try await f.stager.stageReadCredential(
            enrollmentID: f.lifecycle.enrollmentID,
            legacyKey: f.oldKey, binding: f.binding, expectedGeneration: 1
        )
    }
    #expect(try await f.journal.record(for: f.lifecycle.enrollmentID)?.phase ==
        .legacyActive)
    #expect(try await f.destination.load(for: f.lifecycle.key) == nil)
}

@Test
func migrationRejectsWrongAccountAppAndConnectionBinding() async throws {
    let f = try await migrationContext()
    let bad = GitHubLegacyMigrationBinding(
        connectionID: UUID(),
        numericAccountID: "999",
        canonicalWebOrigin: "https://wrong.example",
        appClientID: "Iv1.foreign"
    )
    await #expect(throws: GitHubCredentialMigrationStagingError.identityBindingMismatch) {
        try await f.stager.stageReadCredential(
            enrollmentID: f.lifecycle.enrollmentID,
            legacyKey: f.oldKey, binding: bad, expectedGeneration: 1
        )
    }
    #expect(try await f.destination.load(for: f.lifecycle.key) == nil)
    #expect(await f.legacy.deletionCount() == 0)
}

@Test
func migrationMissingLegacyCannotPromoteAuthorization() async throws {
    let f = try await migrationContext(hasLegacy: false)
    await #expect(throws: GitHubCredentialMigrationStagingError.legacyCredentialMissing) {
        try await f.stager.stageReadCredential(
            enrollmentID: f.lifecycle.enrollmentID,
            legacyKey: f.oldKey, binding: f.binding, expectedGeneration: 1
        )
    }
    #expect(try await f.journal.record(for: f.lifecycle.enrollmentID)?.phase ==
        .legacyActive)
}

@Test
func migrationNeverSilentlyUpgradesReadTokenToWriteGrant() async throws {
    let f = try await migrationContext(purpose: .write)
    await #expect(throws: GitHubCredentialMigrationStagingError.writeEnrollmentNotMigratable) {
        try await f.stager.stageReadCredential(
            enrollmentID: f.lifecycle.enrollmentID,
            legacyKey: f.oldKey, binding: f.binding, expectedGeneration: 1
        )
    }
    #expect(try await f.destination.load(for: f.lifecycle.key) == nil)
}

@Test
func disconnectDuringStagingPreventsDpActivePromotion() async throws {
    let f = try await migrationContext()
    let enrollmentID = f.lifecycle.enrollmentID
    let journal = f.journal
    await f.destination.beforeInsert {
        _ = try await journal.transition(
            enrollmentID: enrollmentID,
            expectedGeneration: 2,
            to: .disconnected
        )
    }
    await #expect(throws: GitHubCredentialEnrollmentTransitionError.staleGeneration) {
        try await f.stager.stageReadCredential(
            enrollmentID: enrollmentID,
            legacyKey: f.oldKey,
            binding: f.binding,
            expectedGeneration: 1
        )
    }
    #expect(try await f.journal.record(for: enrollmentID)?.phase == .disconnected)
    #expect(try await f.legacy.load(for: f.oldKey) == f.credential)
    #expect(await f.legacy.deletionCount() == 0)
}

@Test
func migrationStagingInsertsUsingPreparedBoundEnrollmentSnapshot() async throws {
    let f = try await migrationContext()
    let result = try await f.stager.stageReadCredential(
        enrollmentID: f.lifecycle.enrollmentID,
        legacyKey: f.oldKey,
        binding: f.binding,
        expectedGeneration: 1
    )
    #expect(result.phase == .dpActive)
    #expect(result.generation == 3)
    #expect(try await f.destination.load(for: result.key) == f.credential)
}

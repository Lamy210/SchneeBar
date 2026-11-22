import Foundation
import Testing
@testable import SchneeBarGitHub

private enum JournalFixtureError: Error, Equatable { case injectedFailure }

private final class CredentialJournalMemoryFixture: GitHubCredentialEnrollmentJournalPersistence, @unchecked Sendable {
    private let lock = NSLock()
    private var records: [GitHubCredentialEnrollmentLifecycle] = []
    private var failure: Bool = false
    private var commitThenFail: Bool = false
    private var failReadOnce: Bool = false

    func failNextLoad() {
        lock.lock()
        defer { lock.unlock() }
        failReadOnce = true
    }

    func failNextReplacement(afterCommitting: Bool) {
        lock.lock()
        defer { lock.unlock() }
        failure = true
        commitThenFail = afterCommitting
    }

    func load() throws -> [GitHubCredentialEnrollmentLifecycle] {
        lock.lock()
        defer { lock.unlock() }
        if failReadOnce {
            failReadOnce = false
            throw JournalFixtureError.injectedFailure
        }
        return records
    }

    func compareAndReplace(
        expected: [GitHubCredentialEnrollmentLifecycle],
        next newRecords: [GitHubCredentialEnrollmentLifecycle]
    ) throws {
        lock.lock()
        defer { lock.unlock() }
        guard records == expected else {
            throw GitHubCredentialEnrollmentJournalError.staleSnapshot
        }
        if failure {
            failure = false
            if commitThenFail { records = newRecords }
            throw JournalFixtureError.injectedFailure
        }
        records = newRecords
    }

    func forceLoadFixture(_ values: [GitHubCredentialEnrollmentLifecycle]) {
        lock.lock()
        defer { lock.unlock() }
        records = values
    }
}

private func journalFixtureState(_ uuid: UUID = UUID()) throws -> GitHubCredentialEnrollmentLifecycle {
    try .init(
        enrollmentID: uuid, purpose: .read,
        canonicalWebOrigin: "https://github.com",
        numericAccountID: "123", appClientID: "Iv1.fixture"
    )
}

@Test
func journalRejectsDuplicateAndPersistsNewConsentIndependently() async throws {
    let persistence = CredentialJournalMemoryFixture()
    let journal = GitHubCredentialEnrollmentJournal(persistence: persistence)
    let a = try journalFixtureState()
    let b = try journalFixtureState()
    _ = try await journal.register(a)
    _ = try await journal.register(b)
    await #expect(throws: GitHubCredentialEnrollmentJournalError.duplicateEnrollment) {
        try await journal.register(a)
    }
    #expect(try await journal.record(for: a.enrollmentID) == a)
    #expect(try await journal.record(for: b.enrollmentID) == b)
    let reopened = GitHubCredentialEnrollmentJournal(persistence: persistence)
    #expect(try await reopened.record(for: a.enrollmentID) == a)
}

@Test
func journalPersistedGenerationRejectsStaleAsyncCompletion() async throws {
    let persistence = CredentialJournalMemoryFixture()
    let journal = GitHubCredentialEnrollmentJournal(persistence: persistence)
    let a = try journalFixtureState()
    _ = try await journal.register(a)
    let active = try await journal.transition(
        enrollmentID: a.enrollmentID, expectedGeneration: 1, to: .dpActive
    )
    let disconnected = try await journal.transition(
        enrollmentID: a.enrollmentID, expectedGeneration: 2, to: .disconnected
    )
    #expect(disconnected.generation == 3)
    #expect(active.generation == 2)
    await #expect(throws: GitHubCredentialEnrollmentTransitionError.staleGeneration) {
        try await journal.transition(
            enrollmentID: a.enrollmentID, expectedGeneration: 2, to: .refreshInFlight
        )
    }
    let reopened = GitHubCredentialEnrollmentJournal(persistence: persistence)
    #expect(try await reopened.record(for: a.enrollmentID) == disconnected)
}

@Test
func journalFailsClosedBeforeAndAfterInjectedPersistenceErrors() async throws {
    let persistence = CredentialJournalMemoryFixture()
    let journal = GitHubCredentialEnrollmentJournal(persistence: persistence)
    let a = try journalFixtureState()
    _ = try await journal.register(a)

    persistence.failNextReplacement(afterCommitting: false)
    do {
        _ = try await journal.transition(
            enrollmentID: a.enrollmentID, expectedGeneration: 1, to: .dpActive
        )
        Issue.record("Transition must not be acknowledged on failed write")
    } catch JournalFixtureError.injectedFailure {
        // Expected.
    }
    #expect(try await journal.record(for: a.enrollmentID) == a)

    persistence.failNextReplacement(afterCommitting: true)
    do {
        _ = try await journal.transition(
            enrollmentID: a.enrollmentID, expectedGeneration: 1, to: .dpActive
        )
        Issue.record("Transition must not be acknowledged after uncertain fsync")
    } catch JournalFixtureError.injectedFailure {
        // Expected. Storage may have advanced: reload is mandatory.
    }
    let persisted = try #require(try await journal.record(for: a.enrollmentID))
    #expect(persisted.phase == .dpActive)
    #expect(persisted.generation == 2)
    await #expect(throws: GitHubCredentialEnrollmentTransitionError.staleGeneration) {
        try await journal.transition(
            enrollmentID: a.enrollmentID, expectedGeneration: 1, to: .disconnected
        )
    }
}

@Test
func journalRefusesDuplicateIDsInLoadedSnapshot() async throws {
    let memory = CredentialJournalMemoryFixture()
    let a = try journalFixtureState()
    memory.forceLoadFixture([a, a])
    let journal = GitHubCredentialEnrollmentJournal(persistence: memory)
    await #expect(throws: GitHubCredentialEnrollmentJournalError.invalidSnapshot) {
        try await journal.record(for: a.enrollmentID)
    }
}

@Test
func twoJournalsRejectLostUpdateAfterIndependentCacheLoad() async throws {
    let persistence = CredentialJournalMemoryFixture()
    let first = GitHubCredentialEnrollmentJournal(persistence: persistence)
    let second = GitHubCredentialEnrollmentJournal(persistence: persistence)
    let enrollment = try journalFixtureState()

    _ = try await first.register(enrollment)
    _ = try await second.record(for: enrollment.enrollmentID)
    let active = try await first.transition(
        enrollmentID: enrollment.enrollmentID, expectedGeneration: 1, to: .dpActive
    )
    #expect(active.generation == 2)
    await #expect(throws: GitHubCredentialEnrollmentJournalError.staleSnapshot) {
        try await second.transition(
            enrollmentID: enrollment.enrollmentID,
            expectedGeneration: 1, to: .disconnected
        )
    }
    #expect(try await second.record(for: enrollment.enrollmentID) == active)
}


@Test
func journalRefreshObservesExternalDisconnectDespiteCachedActiveState() async throws {
    let persistence = CredentialJournalMemoryFixture()
    let first = GitHubCredentialEnrollmentJournal(persistence: persistence)
    let second = GitHubCredentialEnrollmentJournal(persistence: persistence)
    let enrollment = try journalFixtureState()

    _ = try await first.register(enrollment)
    let active = try await first.transition(
        enrollmentID: enrollment.enrollmentID,
        expectedGeneration: 1,
        to: .dpActive
    )
    #expect(active.generation == 2)
    // The second actor uses its own snapshot and persists a disconnect.
    _ = try await second.record(for: enrollment.enrollmentID)
    let disconnected = try await second.transition(
        enrollmentID: enrollment.enrollmentID,
        expectedGeneration: 2,
        to: .disconnected
    )

    // An ordinary cached lookup cannot attest to another process's state.
    #expect(try await first.record(for: enrollment.enrollmentID) == active)
    #expect(try await first.refreshRecord(for: enrollment.enrollmentID) == disconnected)
    #expect(try await first.record(for: enrollment.enrollmentID) == disconnected)
}

@Test
func journalRefreshRejectsCorruptExternalSnapshotWithoutKeepingOldCache() async throws {
    let persistence = CredentialJournalMemoryFixture()
    let journal = GitHubCredentialEnrollmentJournal(persistence: persistence)
    let enrollment = try journalFixtureState()
    _ = try await journal.register(enrollment)
    let active = try await journal.transition(
        enrollmentID: enrollment.enrollmentID,
        expectedGeneration: 1, to: .dpActive
    )

    // Simulate corrupted disk/connector contents with a duplicated ID.
    persistence.forceLoadFixture([active, active])
    #expect(throws: GitHubCredentialEnrollmentJournalError.invalidSnapshot) {
        try await journal.refreshRecord(for: enrollment.enrollmentID)
    }

    // The old dpActive must not survive the failed refresh.
    let disconnected = try active.transitioned(
        to: .disconnected, expectedGeneration: 2
    )
    persistence.forceLoadFixture([disconnected])
    #expect(try await journal.record(for: enrollment.enrollmentID) == disconnected)
}

@Test
func journalRefreshReadFailureDoesNotReturnCachedActiveEnrollment() async throws {
    let persistence = CredentialJournalMemoryFixture()
    let journal = GitHubCredentialEnrollmentJournal(persistence: persistence)
    let enrollment = try journalFixtureState()
    _ = try await journal.register(enrollment)
    let active = try await journal.transition(
        enrollmentID: enrollment.enrollmentID,
        expectedGeneration: 1, to: .dpActive
    )
    persistence.failNextLoad()
    #expect(throws: JournalFixtureError.injectedFailure) {
        try await journal.refreshRecord(for: enrollment.enrollmentID)
    }
    // Follow-up reads must reload rather than reuse the earlier cached dpActive.
    let disconnected = try active.transitioned(
        to: .disconnected, expectedGeneration: 2
    )
    persistence.forceLoadFixture([disconnected])
    #expect(try await journal.record(for: enrollment.enrollmentID) == disconnected)
    #expect(try await journal.refreshRecord(for: UUID()) == nil)
}

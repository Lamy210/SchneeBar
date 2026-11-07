import Foundation
import Testing
@testable import SchneeBarGitHub

private enum JournalFixtureError: Error { case injectedFailure }

private final class CredentialJournalMemoryFixture: GitHubCredentialEnrollmentJournalPersistence, @unchecked Sendable {
    private let lock = NSLock()
    private var records: [GitHubCredentialEnrollmentLifecycle] = []
    private var failure: Bool = false
    private var commitThenFail: Bool = false

    func failNextReplacement(afterCommitting: Bool) {
        lock.lock()
        defer { lock.unlock() }
        failure = true
        commitThenFail = afterCommitting
    }

    func load() throws -> [GitHubCredentialEnrollmentLifecycle] {
        lock.lock()
        defer { lock.unlock() }
        return records
    }

    func replace(_ newRecords: [GitHubCredentialEnrollmentLifecycle]) throws {
        lock.lock()
        defer { lock.unlock() }
        if failure {
            failure = false
            if commitThenFail { records = newRecords }
            throw JournalFixtureError.injectedFailure
        }
        records = newRecords
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
    try memory.replace([a, a])
    let journal = GitHubCredentialEnrollmentJournal(persistence: memory)
    await #expect(throws: GitHubCredentialEnrollmentJournalError.invalidSnapshot) {
        try await journal.record(for: a.enrollmentID)
    }
}

import Foundation

public enum GitHubCredentialEnrollmentJournalError: Error, Equatable, Sendable {
    case duplicateEnrollment
    case missingEnrollment
    case invalidSnapshot
    case staleSnapshot
    case inactiveEnrollment
}

/// Implementations must make each replacement durable and crash-safe before
/// returning. This change intentionally provides no production disk adapter:
/// cross-process locking, fsync and symlink handling are separate gates.
public protocol GitHubCredentialEnrollmentJournalPersistence: Sendable {
    func load() throws -> [GitHubCredentialEnrollmentLifecycle]
    /// Compare under the same cross-process lock used for durable replacement.
    /// Stale expected snapshots MUST fail; never blindly replace the file.
    func compareAndReplace(
        expected: [GitHubCredentialEnrollmentLifecycle],
        next: [GitHubCredentialEnrollmentLifecycle]
    ) throws
}

/// In-process serial transition coordinator. A caller must retain the returned
/// persisted generation when completing asynchronous token operations.
/// No Keychain operation is performed by this actor.
public actor GitHubCredentialEnrollmentJournal {
    private let persistence: any GitHubCredentialEnrollmentJournalPersistence
    private var loaded = false
    private var records: [UUID: GitHubCredentialEnrollmentLifecycle] = [:]

    public init(persistence: any GitHubCredentialEnrollmentJournalPersistence) {
        self.persistence = persistence
    }

    public func record(for enrollmentID: UUID) throws -> GitHubCredentialEnrollmentLifecycle? {
        try ensureLoaded()
        return records[enrollmentID]
    }

    /// Reload the durable journal even if this actor cached an earlier
    /// generation. Use before any security-sensitive decision about whether
    /// an enrollment is still active: another process may have disconnected
    /// or rotated it since the last in-process lookup.
    ///
    /// The persistence adapter must take its usual shared cross-process lock
    /// while reading. This is an observation, NOT an atomic lease: another
    /// process can transition immediately after the lock is released. A
    /// production authorization coordinator must additionally fence the
    /// generation for the entire credential-using operation.
    ///
    /// Discard the cached snapshot *before* I/O so failed/corrupt reloads can
    /// never leave an earlier dpActive generation available via record(for:).
    public func refreshRecord(
        for enrollmentID: UUID
    ) throws -> GitHubCredentialEnrollmentLifecycle? {
        records = [:]
        loaded = false
        try ensureLoaded()
        return records[enrollmentID]
    }

    /// Fail-closed preflight for an already known V2 credential generation.
    /// Unlike record(for:), this re-reads the durable snapshot on every call,
    /// rejects stale generations, and requires the dpActive phase.
    ///
    /// IMPORTANT: this is a point-in-time check, not a cross-process lease.
    /// Another process can disconnect immediately afterwards. The future
    /// credential coordinator must recheck/hold the generation fence across
    /// the actual Keychain/API operation. It must never treat this as proof of
    /// account identity or GitHub authorization.
    public func requireFreshActiveRecord(
        for enrollmentID: UUID,
        expectedGeneration: UInt64
    ) throws -> GitHubCredentialEnrollmentLifecycle {
        guard let current = try refreshRecord(for: enrollmentID) else {
            throw GitHubCredentialEnrollmentJournalError.missingEnrollment
        }
        guard current.generation == expectedGeneration else {
            throw GitHubCredentialEnrollmentJournalError.staleSnapshot
        }
        guard current.phase == .dpActive, current.generation >= 2 else {
            throw GitHubCredentialEnrollmentJournalError.inactiveEnrollment
        }
        return current
    }

    public func register(
        _ enrollment: GitHubCredentialEnrollmentLifecycle
    ) throws -> GitHubCredentialEnrollmentLifecycle {
        try ensureLoaded()
        guard records[enrollment.enrollmentID] == nil else {
            throw GitHubCredentialEnrollmentJournalError.duplicateEnrollment
        }
        // A public Codable lifecycle can be decoded without running its
        // throwing initializer. Never persist a forged account, endpoint or
        // client binding even when the phase and generation look plausible.
        guard enrollment.isValidPersistedSnapshot(),
              enrollment.generation == 1,
              enrollment.phase == .prepared || enrollment.phase == .legacyActive
        else {
            throw GitHubCredentialEnrollmentJournalError.invalidSnapshot
        }
        var next = records
        next[enrollment.enrollmentID] = enrollment
        try commit(next)
        return enrollment
    }

    /// Persist the new generation BEFORE the caller uses it to perform any
    /// credential write, migration or cleanup I/O.
    public func transition(
        enrollmentID: UUID,
        expectedGeneration: UInt64,
        to phase: GitHubCredentialEnrollmentPhase
    ) throws -> GitHubCredentialEnrollmentLifecycle {
        try ensureLoaded()
        guard let previous = records[enrollmentID] else {
            throw GitHubCredentialEnrollmentJournalError.missingEnrollment
        }
        let updated = try previous.transitioned(
            to: phase, expectedGeneration: expectedGeneration
        )
        var next = records
        next[enrollmentID] = updated
        try commit(next)
        return updated
    }

    private func ensureLoaded() throws {
        guard !loaded else { return }
        let all = try persistence.load()
        var byID: [UUID: GitHubCredentialEnrollmentLifecycle] = [:]
        for record in all {
            guard record.isValidPersistedSnapshot(),
                  byID.updateValue(record, forKey: record.enrollmentID) == nil
            else {
                throw GitHubCredentialEnrollmentJournalError.invalidSnapshot
            }
        }
        records = byID
        loaded = true
    }

    private func commit(
        _ next: [UUID: GitHubCredentialEnrollmentLifecycle]
    ) throws {
        let sorted = next.values.sorted {
            $0.enrollmentID.uuidString < $1.enrollmentID.uuidString
        }
        do {
            let expected = records.values.sorted {
                $0.enrollmentID.uuidString < $1.enrollmentID.uuidString
            }
            try persistence.compareAndReplace(expected: expected, next: sorted)
            records = next
        } catch {
            // A storage adapter may have committed bytes but failed at its
            // next operation (e.g. fsync). Discard cache and re-read rather
            // than letting an uncertain generation authorize any I/O.
            records = [:]
            loaded = false
            throw error
        }
    }
}

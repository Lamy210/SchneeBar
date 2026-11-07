import Foundation

/// Insert-only V2 credential boundary. The concrete Data Protection Keychain
/// implementation lives in SchneeBarGitHubKeychain; this protocol allows
/// deterministic failure injection without touching real user credentials.
public protocol GitHubCredentialEnrollmentStagingDestination: Sendable {
    func load(for key: GitHubCredentialEnrollmentKey) async throws -> GitHubCredential?
    func insert(_ credential: GitHubCredential, for key: GitHubCredentialEnrollmentKey) async throws
}

/// Evidence that the *caller* has independently checked a connection profile
/// and the provider's authenticated /user response. Merely constructing this
/// value does not prove identity; production callers must provide that proof.
public struct GitHubLegacyMigrationBinding: Equatable, Sendable {
    public let connectionID: UUID
    public let numericAccountID: String
    public let canonicalWebOrigin: String
    public let appClientID: String

    public init(
        connectionID: UUID,
        numericAccountID: String,
        canonicalWebOrigin: String,
        appClientID: String
    ) {
        self.connectionID = connectionID
        self.numericAccountID = numericAccountID
        self.canonicalWebOrigin = canonicalWebOrigin
        self.appClientID = appClientID
    }
}

public enum GitHubCredentialMigrationStagingError: Error, Equatable, Sendable {
    case missingEnrollment
    case staleGeneration
    case unsupportedState
    case writeEnrollmentNotMigratable
    case identityBindingMismatch
    case legacyCredentialMissing
    case endpointBindingUnverified
    case existingV2CredentialMismatch
    case v2ReadbackMismatch
}

/// Opt-in, non-destructive migration staging. There is intentionally no
/// legacy delete, Keychain-wide lookup, token revocation or runtime wiring.
///
/// Source profile / App / provider identity must be verified by the caller
/// before use. The durable enrollment journal MUST be registered and locked
/// by the app's future coordinated migration supervisor. This stage alone
/// cannot prove that other processes have stopped using legacy credentials.
public actor GitHubCredentialMigrationStager {
    private let legacy: any GitHubCredentialStore
    private let destination: any GitHubCredentialEnrollmentStagingDestination
    private let journal: GitHubCredentialEnrollmentJournal

    public init(
        legacy: any GitHubCredentialStore,
        destination: any GitHubCredentialEnrollmentStagingDestination,
        journal: GitHubCredentialEnrollmentJournal
    ) {
        self.legacy = legacy
        self.destination = destination
        self.journal = journal
    }

    /// Copies only one exact legacy key into the enrollment-specific V2 slot
    /// and reads it back BEFORE committing dpActive. The legacy item stays
    /// untouched on success, failure, cancellation and retry.
    ///
    /// An interrupted migration can resume from migrationPrepared with the
    /// journal's *current* generation and the same validated binding.
    public func stageReadCredential(
        enrollmentID: UUID,
        legacyKey: GitHubCredentialKey,
        binding: GitHubLegacyMigrationBinding,
        expectedGeneration: UInt64
    ) async throws -> GitHubCredentialEnrollmentLifecycle {
        try Task.checkCancellation()
        guard let initial = try await journal.record(for: enrollmentID) else {
            throw GitHubCredentialMigrationStagingError.missingEnrollment
        }
        guard initial.generation == expectedGeneration else {
            throw GitHubCredentialMigrationStagingError.staleGeneration
        }
        guard initial.purpose == .read else {
            throw GitHubCredentialMigrationStagingError.writeEnrollmentNotMigratable
        }
        guard initial.phase == .legacyActive ||
              initial.phase == .migrationPrepared else {
            throw GitHubCredentialMigrationStagingError.unsupportedState
        }
        guard legacyKey.connectionID == binding.connectionID,
              legacyKey.accountID == initial.numericAccountID,
              binding.numericAccountID == initial.numericAccountID,
              binding.canonicalWebOrigin == initial.canonicalWebOrigin,
              binding.appClientID == initial.appClientID else {
            throw GitHubCredentialMigrationStagingError.identityBindingMismatch
        }

        guard let candidate = try await legacy.load(for: legacyKey) else {
            throw GitHubCredentialMigrationStagingError.legacyCredentialMissing
        }
        // Legacy records without an endpoint binding are not silently
        // promoted. The caller must reauthenticate and verify the provider.
        guard let endpoint = candidate.endpointIdentity,
              endpoint == initial.canonicalWebOrigin else {
            throw GitHubCredentialMigrationStagingError.endpointBindingUnverified
        }
        try Task.checkCancellation()

        let prepared: GitHubCredentialEnrollmentLifecycle
        if initial.phase == .legacyActive {
            prepared = try await journal.transition(
                enrollmentID: enrollmentID,
                expectedGeneration: expectedGeneration,
                to: .migrationPrepared
            )
        } else {
            prepared = initial
        }
        try Task.checkCancellation()
        if let existing = try await destination.load(for: prepared.key) {
            guard existing == candidate else {
                throw GitHubCredentialMigrationStagingError.existingV2CredentialMismatch
            }
        } else {
            // A crash after insertion may leave the V2 item present while the
            // journal still says migrationPrepared. Resume verifies exact
            // equality rather than overwriting it or deleting the old item.
            try await destination.insert(candidate, for: prepared.key)
        }
        guard try await destination.load(for: prepared.key) == candidate else {
            throw GitHubCredentialMigrationStagingError.v2ReadbackMismatch
        }
        try Task.checkCancellation()
        // The transition is CAS-fenced against concurrent disconnect, refresh
        // and re-enrollment. A failure leaves legacy intact; a staged V2 item
        // cannot grant access without the persisted dpActive decision.
        let promoted = try await journal.transition(
            enrollmentID: enrollmentID,
            expectedGeneration: prepared.generation,
            to: .dpActive
        )
        return promoted
    }
}

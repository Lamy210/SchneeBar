import Foundation

/// A pure, non-networking policy model for one GitHub credential enrollment.
/// The caller must durably persist each transition BEFORE acting on it.
/// This type is not a substitute for a cross-process journal/lock.
public enum GitHubCredentialEnrollmentPhase: String, Codable, Equatable, Sendable {
    case prepared
    case legacyActive
    case migrationPrepared
    case dpActive
    case refreshInFlight
    case reauthRequired
    case disconnected
}

public enum GitHubCredentialEnrollmentTransitionError: Error, Equatable, Sendable {
    case invalidIdentity
    case staleGeneration
    case invalidTransition
    case generationExhausted
}

/// A reference to an already persisted disconnect tombstone, NOT permission
/// to delete a Keychain item by itself. The future cleanup coordinator also
/// must verify exact item ownership and its persisted generation.
public struct GitHubCredentialEnrollmentCleanupScope: Equatable, Codable, Sendable {
    public let enrollmentID: UUID
    public let purpose: GitHubCredentialAuthorizationPurpose
    public let disconnectedGeneration: UInt64
    public let storageAccount: String
}

public struct GitHubCredentialEnrollmentLifecycle: Codable, Equatable, Sendable {
    public let enrollmentID: UUID
    public let purpose: GitHubCredentialAuthorizationPurpose
    public let canonicalWebOrigin: String
    public let numericAccountID: String
    public let appClientID: String
    public private(set) var phase: GitHubCredentialEnrollmentPhase
    public private(set) var generation: UInt64

    public var key: GitHubCredentialEnrollmentKey {
        .init(enrollmentID: enrollmentID, purpose: purpose)
    }

    public init(
        enrollmentID: UUID,
        purpose: GitHubCredentialAuthorizationPurpose,
        canonicalWebOrigin: String,
        numericAccountID: String,
        appClientID: String
    ) throws {
        guard let url = URLComponents(string: canonicalWebOrigin),
              url.scheme?.lowercased() == "https",
              let host = url.host, !host.isEmpty,
              url.user == nil, url.password == nil,
              url.query == nil, url.fragment == nil,
              let numericID = Int64(numericAccountID),
              numericID > 0, String(numericID) == numericAccountID,
              !appClientID.isEmpty,
              appClientID == appClientID.trimmingCharacters(in: .whitespacesAndNewlines),
              !appClientID.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) })
        else {
            throw GitHubCredentialEnrollmentTransitionError.invalidIdentity
        }
        self.enrollmentID = enrollmentID
        self.purpose = purpose
        self.canonicalWebOrigin = canonicalWebOrigin
        self.numericAccountID = numericAccountID
        self.appClientID = appClientID
        self.phase = .prepared
        self.generation = 1
    }

    /// This constructor must only be called AFTER the caller has validated the
    /// exact legacy Keychain record and bound it to the current provider.
    /// It does not read a Keychain item or attest that verification itself.
    public static func prepareVerifiedLegacy(
        enrollmentID: UUID,
        purpose: GitHubCredentialAuthorizationPurpose,
        canonicalWebOrigin: String,
        numericAccountID: String,
        appClientID: String
    ) throws -> Self {
        var state = try Self(
            enrollmentID: enrollmentID,
            purpose: purpose,
            canonicalWebOrigin: canonicalWebOrigin,
            numericAccountID: numericAccountID,
            appClientID: appClientID
        )
        state.phase = .legacyActive
        return state
    }

    /// The expected generation is checked before creating the next immutable
    /// snapshot. Apply only after the journal CAS/durable write succeeded.
    public func transitioned(
        to next: GitHubCredentialEnrollmentPhase,
        expectedGeneration: UInt64
    ) throws -> Self {
        guard generation == expectedGeneration else {
            throw GitHubCredentialEnrollmentTransitionError.staleGeneration
        }
        guard Self.isAllowed(from: phase, to: next) else {
            throw GitHubCredentialEnrollmentTransitionError.invalidTransition
        }
        guard generation < UInt64.max else {
            throw GitHubCredentialEnrollmentTransitionError.generationExhausted
        }
        var result = self
        result.generation += 1
        result.phase = next
        return result
    }

    /// Only a persisted disconnected snapshot may authorize cleanup. This
    /// predicate is a necessary, never a sufficient, deletion condition.
    public func matchesDisconnectedCleanup(
        _ scope: GitHubCredentialEnrollmentCleanupScope
    ) -> Bool {
        phase == .disconnected &&
        scope.enrollmentID == enrollmentID &&
        scope.purpose == purpose &&
        scope.disconnectedGeneration == generation &&
        scope.storageAccount == key.storageAccount
    }

    public var disconnectedCleanupScope: GitHubCredentialEnrollmentCleanupScope? {
        guard phase == .disconnected else { return nil }
        return .init(
            enrollmentID: enrollmentID,
            purpose: purpose,
            disconnectedGeneration: generation,
            storageAccount: key.storageAccount
        )
    }

    private static func isAllowed(
        from current: GitHubCredentialEnrollmentPhase,
        to next: GitHubCredentialEnrollmentPhase
    ) -> Bool {
        if next == .disconnected { return current != .disconnected }
        switch (current, next) {
        case (.prepared, .dpActive), (.prepared, .reauthRequired),
             (.legacyActive, .migrationPrepared), (.legacyActive, .refreshInFlight),
             (.legacyActive, .reauthRequired),
             (.migrationPrepared, .legacyActive), (.migrationPrepared, .dpActive),
             (.migrationPrepared, .reauthRequired),
             (.dpActive, .refreshInFlight), (.dpActive, .reauthRequired),
             (.refreshInFlight, .dpActive), (.refreshInFlight, .reauthRequired):
            return true
        default:
            return false
        }
    }
}

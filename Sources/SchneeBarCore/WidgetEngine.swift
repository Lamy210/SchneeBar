import Foundation

public struct WidgetProviderGroupID: Hashable, Sendable {
    public static let maximumUTF8Bytes = 64

    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    public var isValidNamespace: Bool {
        guard !rawValue.isEmpty,
              rawValue.utf8.count <= Self.maximumUTF8Bytes
        else {
            return false
        }

        let segments = rawValue.split(
            separator: ".",
            omittingEmptySubsequences: false
        )
        return segments.allSatisfy { segment in
            guard !segment.isEmpty,
                  let first = segment.unicodeScalars.first,
                  let last = segment.unicodeScalars.last,
                  Self.isASCIILowercaseLetterOrDigit(first),
                  Self.isASCIILowercaseLetterOrDigit(last)
            else {
                return false
            }

            return segment.unicodeScalars.allSatisfy { scalar in
                let value = scalar.value
                return Self.isASCIILowercaseLetterOrDigit(scalar)
                    || value == 95
            }
        }
    }

    private static func isASCIILowercaseLetterOrDigit(
        _ scalar: Unicode.Scalar
    ) -> Bool {
        let value = scalar.value
        return (value >= 48 && value <= 57)
            || (value >= 97 && value <= 122)
    }
}

public enum WidgetProviderRegistrationError: Error, Equatable, Sendable {
    case invalidProviderID
    case invalidDisplayName
    case invalidRefreshPolicy
}

public enum WidgetProviderBatchUpdateError: Error, Equatable, Sendable {
    case invalidProviderGroupID
    case invalidProviderID
    case invalidDisplayName
    case invalidRefreshPolicy
    case duplicateProviderID(WidgetID)
    case providerAlreadyRegistered(WidgetID)
}

private enum WidgetProviderContractViolation: Error {
    case snapshotDescriptorMismatch
}

private struct RegisteredWidgetProvider: Sendable {
    let provider: any WidgetProvider
    let descriptor: WidgetDescriptor

    init(_ provider: any WidgetProvider) {
        self.provider = provider
        descriptor = provider.descriptor
    }
}

public actor WidgetEngine {
    private var providers: [WidgetID: RegisteredWidgetProvider]
    private var providerGroups: [WidgetProviderGroupID: Set<WidgetID>] = [:]
    private var snapshots: [WidgetID: WidgetSnapshot] = [:]
    private var lastAttemptedAt: [WidgetID: Date] = [:]
    private var lastSucceededAt: [WidgetID: Date] = [:]
    private var lastFailureAt: [WidgetID: Date] = [:]
    private var consecutiveFailureCount: [WidgetID: Int] = [:]
    private var providerRevision: [WidgetID: UInt64] = [:]
    private var refreshSequence: [WidgetID: UInt64] = [:]
    private var lastAppliedRefreshSequence: [WidgetID: UInt64] = [:]
    private var configuration: WidgetConfiguration

    /// Creates the engine from trusted, App-composed bootstrap providers.
    ///
    /// Dynamic or externally sourced providers must use the throwing mutation
    /// APIs below. Persisted WidgetPreference IDs remain permissively decoded
    /// and never become registration capability by themselves.
    public init(
        providers: [any WidgetProvider] = [],
        configuration: WidgetConfiguration = .init()
    ) {
        let registrations = providers.map(RegisteredWidgetProvider.init)
        let ids = registrations.map(\.descriptor.id)
        precondition(
            ids.allSatisfy { $0.isValidProviderID },
            "Trusted WidgetEngine providers must use valid provider IDs."
        )
        precondition(
            registrations.allSatisfy {
                Self.hasValidDisplayName(
                    $0.descriptor.displayName
                )
            },
            "Trusted WidgetEngine providers must use canonical display names."
        )
        precondition(
            registrations.allSatisfy {
                Self.hasFiniteRefreshPolicy(
                    $0.descriptor.refreshPolicy
                )
            },
            "Trusted WidgetEngine providers must use finite refresh policies."
        )
        precondition(
            Set(ids).count == ids.count,
            "Trusted WidgetEngine providers must use unique IDs."
        )

        self.providers = Dictionary(
            uniqueKeysWithValues: zip(ids, registrations)
        )
        self.configuration = configuration
    }

    public func register(_ provider: any WidgetProvider) throws {
        try Task.checkCancellation()

        let registration = RegisteredWidgetProvider(provider)
        let id = registration.descriptor.id
        guard id.isValidProviderID else {
            throw WidgetProviderRegistrationError.invalidProviderID
        }
        guard Self.hasValidDisplayName(
            registration.descriptor.displayName
        ) else {
            throw WidgetProviderRegistrationError.invalidDisplayName
        }
        guard Self.hasFiniteRefreshPolicy(
            registration.descriptor.refreshPolicy
        ) else {
            throw WidgetProviderRegistrationError.invalidRefreshPolicy
        }

        detachFromProviderGroups(id: id)
        providers[id] = registration
        invalidateProviderRevision(id: id)
        resetRuntimeState(id: id)
    }

    public func unregister(id: WidgetID) {
        detachFromProviderGroups(id: id)
        providers.removeValue(forKey: id)
        invalidateProviderRevision(id: id)
        resetRuntimeState(id: id)
    }

    public func replaceProviders(
        in groupID: WidgetProviderGroupID,
        with replacements: [any WidgetProvider]
    ) throws {
        try Task.checkCancellation()

        guard groupID.isValidNamespace else {
            throw WidgetProviderBatchUpdateError.invalidProviderGroupID
        }

        let registrations = replacements.map(
            RegisteredWidgetProvider.init
        )
        for registration in registrations {
            guard registration.descriptor.id.isValidProviderID else {
                throw WidgetProviderBatchUpdateError.invalidProviderID
            }
        }
        for registration in registrations {
            guard Self.hasValidDisplayName(
                registration.descriptor.displayName
            ) else {
                throw WidgetProviderBatchUpdateError.invalidDisplayName
            }
        }
        for registration in registrations {
            guard Self.hasFiniteRefreshPolicy(
                registration.descriptor.refreshPolicy
            ) else {
                throw WidgetProviderBatchUpdateError.invalidRefreshPolicy
            }
        }

        var replacementByID: [WidgetID: RegisteredWidgetProvider] = [:]
        replacementByID.reserveCapacity(registrations.count)

        for registration in registrations {
            let id = registration.descriptor.id
            guard replacementByID[id] == nil else {
                throw WidgetProviderBatchUpdateError.duplicateProviderID(id)
            }
            replacementByID[id] = registration
        }

        let previousIDs = providerGroups[groupID] ?? []
        for id in replacementByID.keys
        where providers[id] != nil && !previousIDs.contains(id)
        {
            throw WidgetProviderBatchUpdateError.providerAlreadyRegistered(id)
        }

        let replacementIDs = Set(replacementByID.keys)
        let affectedIDs = previousIDs.union(replacementIDs)

        try Task.checkCancellation()

        for id in previousIDs {
            providers.removeValue(forKey: id)
        }
        for (id, provider) in replacementByID {
            providers[id] = provider
        }

        if replacementIDs.isEmpty {
            providerGroups.removeValue(forKey: groupID)
        } else {
            providerGroups[groupID] = replacementIDs
        }

        for id in affectedIDs {
            invalidateProviderRevision(id: id)
            resetRuntimeState(id: id)
        }
    }

    public func setConfiguration(_ configuration: WidgetConfiguration) {
        let previousConfiguration = self.configuration
        self.configuration = configuration

        for (id, registration) in providers {
            let descriptor = registration.descriptor
            let wasEnabled = previousConfiguration.isEnabled(descriptor)
            let isEnabled = configuration.isEnabled(descriptor)
            if !wasEnabled && isEnabled {
                lastAttemptedAt.removeValue(forKey: id)
            }
        }
    }

    public func currentConfiguration() -> WidgetConfiguration {
        configuration
    }

    public func descriptors() -> [WidgetDescriptor] {
        providers.values
            .map(\.descriptor)
            .sorted { lhs, rhs in
                let lhsOrder = configuration.order(for: lhs)
                let rhsOrder = configuration.order(for: rhs)
                if lhsOrder != rhsOrder {
                    return lhsOrder < rhsOrder
                }
                return lhs.id.rawValue < rhs.id.rawValue
            }
    }

    @discardableResult
    public func refresh(id: WidgetID, at attemptedAt: Date = .now) async -> WidgetSnapshot? {
        guard !Task.isCancelled else {
            return snapshots[id]
        }
        guard let registration = providers[id] else { return nil }

        let provider = registration.provider
        let registeredDescriptor = registration.descriptor
        let providerRevision = providerRevision[id] ?? 0
        let sequence = nextRefreshSequence(id: id)
        lastAttemptedAt[id] = attemptedAt

        do {
            let snapshot = try await provider.snapshot()
            guard !Task.isCancelled else {
                return snapshots[id]
            }
            guard snapshot.descriptor == registeredDescriptor else {
                throw WidgetProviderContractViolation
                    .snapshotDescriptorMismatch
            }
            guard isCurrentProviderRevision(providerRevision, id: id),
                  canApplyRefresh(sequence, id: id)
            else {
                return snapshots[id]
            }

            markRefreshApplied(sequence, id: id)
            snapshots[id] = snapshot
            lastSucceededAt[id] = attemptedAt
            consecutiveFailureCount[id] = 0
            return snapshot
        } catch is CancellationError {
            return snapshots[id]
        } catch {
            guard !Task.isCancelled else {
                return snapshots[id]
            }
            guard isCurrentProviderRevision(providerRevision, id: id),
                  canApplyRefresh(sequence, id: id)
            else {
                return snapshots[id]
            }

            markRefreshApplied(sequence, id: id)
            lastFailureAt[id] = attemptedAt
            consecutiveFailureCount[id, default: 0] += 1

            // Preserve the last known-good value. Provider-specific errors are
            // intentionally discarded; callers can inspect provider-neutral
            // runtime diagnostics instead.
            return snapshots[id]
        }
    }

    @discardableResult
    public func refreshAll(at attemptedAt: Date = .now) async -> [WidgetSnapshot] {
        for id in orderedEnabledProviderIDs() {
            guard !Task.isCancelled else { break }
            _ = await refresh(id: id, at: attemptedAt)
        }
        return orderedVisibleSnapshots()
    }

    @discardableResult
    public func refreshDue(at now: Date = .now) async -> [WidgetSnapshot] {
        for id in orderedEnabledProviderIDs() where isRefreshDue(id: id, at: now) {
            guard !Task.isCancelled else { break }
            _ = await refresh(id: id, at: now)
        }
        return orderedVisibleSnapshots()
    }

    public func secondsUntilNextRefresh(
        at now: Date = .now,
        maximum: TimeInterval = 60
    ) -> TimeInterval {
        let intervals = providers.compactMap { id, registration -> TimeInterval? in
            guard configuration.isEnabled(registration.descriptor) else { return nil }
            guard let lastAttempted = lastAttemptedAt[id] else { return 0 }

            let severity = snapshots[id]?.severity ?? .unavailable
            guard let interval = registration.descriptor.refreshPolicy.interval(for: severity) else {
                return nil
            }

            let next = lastAttempted.addingTimeInterval(interval)
            return max(0, next.timeIntervalSince(now))
        }

        return min(intervals.min() ?? maximum, maximum)
    }

    public func snapshot(id: WidgetID) -> WidgetSnapshot? {
        snapshots[id]
    }

    public func diagnostic(id: WidgetID) -> WidgetRuntimeDiagnostic? {
        guard let provider = providers[id] else { return nil }
        return makeDiagnostic(id: id, descriptor: provider.descriptor)
    }

    public func diagnostics() -> [WidgetRuntimeDiagnostic] {
        providers
            .map { id, registration in
                makeDiagnostic(
                    id: id,
                    descriptor: registration.descriptor
                )
            }
            .sorted { lhs, rhs in
                let lhsOrder = configuration.order(for: lhs.descriptor)
                let rhsOrder = configuration.order(for: rhs.descriptor)
                if lhsOrder != rhsOrder {
                    return lhsOrder < rhsOrder
                }
                return lhs.descriptor.id.rawValue < rhs.descriptor.id.rawValue
            }
    }

    public func orderedVisibleSnapshots() -> [WidgetSnapshot] {
        snapshots.values
            .filter { snapshot in
                configuration.isEnabled(snapshot.descriptor) && snapshot.isVisible
            }
            .sorted { lhs, rhs in
                if lhs.priority != rhs.priority {
                    return lhs.priority > rhs.priority
                }

                let lhsOrder = configuration.order(for: lhs.descriptor)
                let rhsOrder = configuration.order(for: rhs.descriptor)
                if lhsOrder != rhsOrder {
                    return lhsOrder < rhsOrder
                }

                return lhs.descriptor.id.rawValue < rhs.descriptor.id.rawValue
            }
    }

    private func makeDiagnostic(
        id: WidgetID,
        descriptor: WidgetDescriptor
    ) -> WidgetRuntimeDiagnostic {
        let failures = consecutiveFailureCount[id, default: 0]
        let hasSnapshot = snapshots[id] != nil
        let health: WidgetRuntimeHealth

        if lastAttemptedAt[id] == nil {
            health = .notLoaded
        } else if failures == 0 {
            health = hasSnapshot ? .healthy : .notLoaded
        } else {
            health = hasSnapshot ? .degraded : .unavailable
        }

        return WidgetRuntimeDiagnostic(
            descriptor: descriptor,
            health: health,
            lastAttemptedAt: lastAttemptedAt[id],
            lastSucceededAt: lastSucceededAt[id],
            lastFailureAt: lastFailureAt[id],
            consecutiveFailureCount: failures,
            isServingLastKnownGood: failures > 0 && hasSnapshot,
            snapshotGeneratedAt: snapshots[id]?.generatedAt
        )
    }

    private static func hasValidDisplayName(
        _ displayName: String
    ) -> Bool {
        guard !displayName.isEmpty,
              displayName.count <= 64,
              displayName.utf8.count <= 256,
              displayName == displayName.trimmingCharacters(
                  in: .whitespacesAndNewlines
              ),
              !displayName.unicodeScalars.contains(where: {
                  CharacterSet.controlCharacters.contains($0)
              })
        else {
            return false
        }
        return true
    }

    private static func hasFiniteRefreshPolicy(
        _ policy: WidgetRefreshPolicy
    ) -> Bool {
        switch policy {
        case .manual:
            return true
        case let .interval(interval):
            return interval.isFinite
        case let .adaptive(active, idle):
            return active.isFinite && idle.isFinite
        }
    }

    private func detachFromProviderGroups(id: WidgetID) {
        for groupID in Array(providerGroups.keys) {
            providerGroups[groupID]?.remove(id)
            if providerGroups[groupID]?.isEmpty == true {
                providerGroups.removeValue(forKey: groupID)
            }
        }
    }

    private func invalidateProviderRevision(id: WidgetID) {
        providerRevision[id] = (providerRevision[id] ?? 0) &+ 1
    }

    private func isCurrentProviderRevision(_ revision: UInt64, id: WidgetID) -> Bool {
        providers[id] != nil && (providerRevision[id] ?? 0) == revision
    }

    private func nextRefreshSequence(id: WidgetID) -> UInt64 {
        let sequence = (refreshSequence[id] ?? 0) &+ 1
        refreshSequence[id] = sequence
        return sequence
    }

    private func canApplyRefresh(_ sequence: UInt64, id: WidgetID) -> Bool {
        sequence > (lastAppliedRefreshSequence[id] ?? 0)
    }

    private func markRefreshApplied(_ sequence: UInt64, id: WidgetID) {
        lastAppliedRefreshSequence[id] = sequence
    }

    private func resetRuntimeState(id: WidgetID) {
        snapshots.removeValue(forKey: id)
        lastAttemptedAt.removeValue(forKey: id)
        lastSucceededAt.removeValue(forKey: id)
        lastFailureAt.removeValue(forKey: id)
        consecutiveFailureCount.removeValue(forKey: id)
        refreshSequence.removeValue(forKey: id)
        lastAppliedRefreshSequence.removeValue(forKey: id)
    }

    private func orderedEnabledProviderIDs() -> [WidgetID] {
        providers.values
            .map(\.descriptor)
            .filter { configuration.isEnabled($0) }
            .sorted { lhs, rhs in
                let lhsOrder = configuration.order(for: lhs)
                let rhsOrder = configuration.order(for: rhs)
                if lhsOrder != rhsOrder {
                    return lhsOrder < rhsOrder
                }
                return lhs.id.rawValue < rhs.id.rawValue
            }
            .map(\.id)
    }

    private func isRefreshDue(id: WidgetID, at now: Date) -> Bool {
        guard let registration = providers[id] else { return false }
        guard configuration.isEnabled(registration.descriptor) else { return false }
        guard let lastAttempted = lastAttemptedAt[id] else { return true }

        let severity = snapshots[id]?.severity ?? .unavailable
        guard let interval = registration.descriptor.refreshPolicy.interval(for: severity) else {
            return false
        }

        return now.timeIntervalSince(lastAttempted) >= interval
    }
}

import Foundation

public enum WidgetRuntimeHealth: String, Codable, CaseIterable, Sendable {
    case notLoaded
    case healthy
    case degraded
    case unavailable
}

/// Provider-neutral runtime health for a widget.
///
/// Diagnostics intentionally do not retain provider errors or localized error
/// strings. This prevents credentials, request details, repository names, or
/// other provider-specific data from leaking into generic presentation code.
public struct WidgetRuntimeDiagnostic: Equatable, Sendable {
    public let descriptor: WidgetDescriptor
    public let health: WidgetRuntimeHealth
    public let lastAttemptedAt: Date?
    public let lastSucceededAt: Date?
    public let lastFailureAt: Date?
    public let consecutiveFailureCount: Int
    public let isServingLastKnownGood: Bool
    public let snapshotGeneratedAt: Date?

    public init(
        descriptor: WidgetDescriptor,
        health: WidgetRuntimeHealth,
        lastAttemptedAt: Date?,
        lastSucceededAt: Date?,
        lastFailureAt: Date?,
        consecutiveFailureCount: Int,
        isServingLastKnownGood: Bool,
        snapshotGeneratedAt: Date?
    ) {
        self.descriptor = descriptor
        self.health = health
        self.lastAttemptedAt = lastAttemptedAt
        self.lastSucceededAt = lastSucceededAt
        self.lastFailureAt = lastFailureAt
        self.consecutiveFailureCount = max(0, consecutiveFailureCount)
        self.isServingLastKnownGood = isServingLastKnownGood
        self.snapshotGeneratedAt = snapshotGeneratedAt
    }
}

public extension WidgetRuntimeDiagnostic {
    /// Only label a *matching* successfully rendered reading as stale.
    /// A failed attempt without an earlier successful value is unavailable,
    /// not a stale reading, and stale state must not leak to a replacement
    /// provider that happens to reuse an ID.
    func indicatesStaleReading(for snapshot: WidgetSnapshot) -> Bool {
        descriptor == snapshot.descriptor
            && health == .degraded
            && isServingLastKnownGood
            && lastSucceededAt != nil
    }

    /// A first failed attempt has no last-known-good reading to show.
    /// This is distinct from an unattempted, disabled or hidden widget.
    var indicatesUnavailableReading: Bool {
        health == .unavailable
            && lastAttemptedAt != nil
            && lastSucceededAt == nil
            && consecutiveFailureCount > 0
            && !isServingLastKnownGood
    }
}

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

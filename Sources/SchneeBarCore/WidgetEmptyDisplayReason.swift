import Foundation

/// Explains why no widget value is currently visible.
///
/// This is intentionally provider-neutral: it contains no API response,
/// credential details, or user-provided repository names.
public enum WidgetEmptyDisplayReason: String, Equatable, Sendable {
    case awaitingWidgets
    case allDisabled
    case awaitingFirstReading
    case hiddenByPolicy

    /// Resolve the empty state using the enabled descriptors and the runtime
    /// health captured for the same UI presentation. Callers only display this
    /// when there are no visible snapshots or unavailable-reading rows.
    public static func resolve(
        descriptors: [WidgetDescriptor],
        configuration: WidgetConfiguration,
        diagnosticsByWidgetID: [WidgetID: WidgetRuntimeDiagnostic]
    ) -> Self {
        guard !descriptors.isEmpty else { return .awaitingWidgets }

        let enabled = descriptors.filter { configuration.isEnabled($0) }
        guard !enabled.isEmpty else { return .allDisabled }

        let awaitingReading = enabled.contains { descriptor in
            guard let diagnostic = diagnosticsByWidgetID[descriptor.id],
                  diagnostic.descriptor == descriptor
            else {
                return true
            }
            return diagnostic.health == .notLoaded
        }
        return awaitingReading ? .awaitingFirstReading : .hiddenByPolicy
    }
}

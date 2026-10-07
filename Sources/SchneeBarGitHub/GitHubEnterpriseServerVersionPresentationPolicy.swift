import Foundation

/// App-owned presentation boundary for GHES version metadata.
///
/// This is deliberately not a GitHub protocol grammar or version-length claim.
/// It only keeps provider/persisted metadata bounded and free of Unicode scalar
/// categories that can alter terminal/UI presentation.
public enum GitHubEnterpriseServerVersionPresentationPolicy {
    public static let unknownVersion = "Unknown"

    private static let maximumUTF8Bytes = 128

    public static func normalized(_ rawValue: String) -> String? {
        let value = rawValue.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        guard !value.isEmpty,
              value.utf8.count <= maximumUTF8Bytes,
              !value.unicodeScalars.contains(
                  where: isUnsafePresentationScalar
              )
        else {
            return nil
        }
        return value
    }

    /// Normalizes optional persisted metadata while preserving the semantic
    /// difference between "never discovered" (`nil`) and an invalid non-empty
    /// legacy/tampered value (`Unknown`).
    public static func normalizedPersistedValue(
        _ rawValue: String?
    ) -> String? {
        guard let rawValue else {
            return nil
        }
        let trimmed = rawValue.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        guard !trimmed.isEmpty else {
            return nil
        }
        return normalized(trimmed) ?? unknownVersion
    }

    private static func isUnsafePresentationScalar(
        _ scalar: Unicode.Scalar
    ) -> Bool {
        switch scalar.properties.generalCategory {
        case .control, .format, .lineSeparator, .paragraphSeparator:
            true
        default:
            false
        }
    }
}

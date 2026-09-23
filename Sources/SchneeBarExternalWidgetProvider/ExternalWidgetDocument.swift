import Foundation
import SchneeBarCore

public enum ExternalWidgetVisibility: String, Codable, Equatable, Sendable {
    case always
    case whenNotNominal
}

public enum ExternalWidgetRefreshKind: String, Codable, Equatable, Sendable {
    case manual
    case interval
}

public struct ExternalWidgetRefresh: Codable, Equatable, Sendable {
    public let kind: ExternalWidgetRefreshKind
    public let intervalSeconds: Double?

    public init(
        kind: ExternalWidgetRefreshKind,
        intervalSeconds: Double? = nil
    ) {
        self.kind = kind
        self.intervalSeconds = intervalSeconds
    }
}

public enum ExternalWidgetSeverity: String, Codable, Equatable, Sendable {
    case nominal
    case active
    case attention
    case critical
    case unavailable
}

public enum ExternalWidgetPriority: String, Codable, Equatable, Sendable {
    case background
    case normal
    case attention
    case critical
}

public struct ExternalWidgetContentDocument:
    Codable,
    Equatable,
    Sendable
{
    public let text: String
    public let systemImage: String?
    public let accessibilityLabel: String

    public init(
        text: String,
        systemImage: String? = nil,
        accessibilityLabel: String
    ) {
        self.text = text
        self.systemImage = systemImage
        self.accessibilityLabel = accessibilityLabel
    }
}

public struct ExternalWidgetSnapshotDocument:
    Codable,
    Equatable,
    Sendable
{
    public let generatedAtEpochSeconds: Double?
    public let severity: ExternalWidgetSeverity
    public let priority: ExternalWidgetPriority
    public let compact: ExternalWidgetContentDocument
    public let normal: ExternalWidgetContentDocument
    public let critical: ExternalWidgetContentDocument?

    public init(
        generatedAtEpochSeconds: Double? = nil,
        severity: ExternalWidgetSeverity,
        priority: ExternalWidgetPriority,
        compact: ExternalWidgetContentDocument,
        normal: ExternalWidgetContentDocument,
        critical: ExternalWidgetContentDocument? = nil
    ) {
        self.generatedAtEpochSeconds = generatedAtEpochSeconds
        self.severity = severity
        self.priority = priority
        self.compact = compact
        self.normal = normal
        self.critical = critical
    }
}

public struct ExternalWidgetDocument:
    Codable,
    Equatable,
    Sendable
{
    public let schemaVersion: Int
    public let id: String
    public let displayName: String
    public let defaultOrder: Int
    public let defaultRepresentation: WidgetRepresentationKind
    public let visibility: ExternalWidgetVisibility
    public let refresh: ExternalWidgetRefresh
    public let snapshot: ExternalWidgetSnapshotDocument

    public init(
        schemaVersion: Int = ExternalWidgetDocumentNormalizer.supportedSchemaVersion,
        id: String,
        displayName: String,
        defaultOrder: Int = 1_000,
        defaultRepresentation: WidgetRepresentationKind = .normal,
        visibility: ExternalWidgetVisibility = .always,
        refresh: ExternalWidgetRefresh = .init(kind: .manual),
        snapshot: ExternalWidgetSnapshotDocument
    ) {
        self.schemaVersion = schemaVersion
        self.id = id
        self.displayName = displayName
        self.defaultOrder = defaultOrder
        self.defaultRepresentation = defaultRepresentation
        self.visibility = visibility
        self.refresh = refresh
        self.snapshot = snapshot
    }
}

public struct ExternalWidgetDefinition: Equatable, Sendable {
    public let descriptor: WidgetDescriptor
    public let snapshot: WidgetSnapshot

    public init(
        descriptor: WidgetDescriptor,
        snapshot: WidgetSnapshot
    ) {
        self.descriptor = descriptor
        self.snapshot = snapshot
    }
}

public enum ExternalWidgetDocumentError:
    Error,
    Equatable,
    Sendable
{
    case unsupportedSchemaVersion(Int)
    case invalidWidgetID(String)
    case invalidDisplayName
    case invalidDefaultOrder(Int)
    case invalidDefaultRepresentation
    case invalidRefreshPolicy
    case invalidGeneratedAt
    case invalidContent(field: String)
    case unsupportedSystemImage(String)
    case duplicateWidgetID(WidgetID)
}

public struct ExternalWidgetDocumentNormalizer: Sendable {
    public static let supportedSchemaVersion = 1

    public static let maximumWidgetIDLength = 128
    public static let maximumDisplayNameLength = 80
    public static let minimumDefaultOrder = 1_000
    public static let maximumDefaultOrder = 10_000
    public static let maximumCompactTextLength = 32
    public static let maximumNormalTextLength = 120
    public static let maximumAccessibilityLabelLength = 160
    public static let minimumRefreshInterval: TimeInterval = 5
    public static let maximumRefreshInterval: TimeInterval = 86_400
    public static let maximumClockSkew: TimeInterval = 300

    private static let allowedSystemImages: Set<String> = [
        "arrow.triangle.2.circlepath",
        "bolt",
        "bolt.fill",
        "checkmark.circle",
        "checkmark.circle.fill",
        "circle",
        "circle.fill",
        "clock",
        "exclamationmark.triangle",
        "exclamationmark.triangle.fill",
        "hammer",
        "hammer.fill",
        "xmark.circle",
        "xmark.circle.fill",
    ]

    private let now: @Sendable () -> Date

    public init(
        now: @escaping @Sendable () -> Date = { .now }
    ) {
        self.now = now
    }

    public func normalize(
        _ document: ExternalWidgetDocument
    ) throws -> ExternalWidgetDefinition {
        guard document.schemaVersion == Self.supportedSchemaVersion else {
            throw ExternalWidgetDocumentError.unsupportedSchemaVersion(
                document.schemaVersion
            )
        }

        let id = try normalizedWidgetID(document.id)
        let displayName = try normalizedDisplayName(document.displayName)

        guard (Self.minimumDefaultOrder ... Self.maximumDefaultOrder)
            .contains(document.defaultOrder)
        else {
            throw ExternalWidgetDocumentError.invalidDefaultOrder(
                document.defaultOrder
            )
        }
        guard document.defaultRepresentation != .critical else {
            throw ExternalWidgetDocumentError.invalidDefaultRepresentation
        }

        let refreshPolicy = try normalizedRefreshPolicy(document.refresh)
        let visibilityPolicy: WidgetVisibilityPolicy
        switch document.visibility {
        case .always:
            visibilityPolicy = .always
        case .whenNotNominal:
            visibilityPolicy = .whenNotNominal
        }

        let descriptor = WidgetDescriptor(
            id: id,
            displayName: displayName,
            defaultIsEnabled: false,
            defaultOrder: document.defaultOrder,
            defaultRepresentation: document.defaultRepresentation,
            visibilityPolicy: visibilityPolicy,
            refreshPolicy: refreshPolicy
        )

        let generatedAt = try normalizedGeneratedAt(
            document.snapshot.generatedAtEpochSeconds
        )
        let compact = try normalizedContent(
            document.snapshot.compact,
            field: "compact",
            maximumTextLength: Self.maximumCompactTextLength
        )
        let normal = try normalizedContent(
            document.snapshot.normal,
            field: "normal",
            maximumTextLength: Self.maximumNormalTextLength
        )
        let critical = try document.snapshot.critical.map {
            try normalizedContent(
                $0,
                field: "critical",
                maximumTextLength: Self.maximumNormalTextLength
            )
        }

        let snapshot = WidgetSnapshot(
            descriptor: descriptor,
            generatedAt: generatedAt,
            severity: severity(document.snapshot.severity),
            priority: priority(document.snapshot.priority),
            representations: WidgetRepresentations(
                compact: compact,
                normal: normal,
                critical: critical
            )
        )

        return ExternalWidgetDefinition(
            descriptor: descriptor,
            snapshot: snapshot
        )
    }

    public func normalize(
        _ documents: [ExternalWidgetDocument]
    ) throws -> [ExternalWidgetDefinition] {
        var seen = Set<WidgetID>()
        var definitions: [ExternalWidgetDefinition] = []
        definitions.reserveCapacity(documents.count)

        for document in documents {
            let definition = try normalize(document)
            guard seen.insert(definition.descriptor.id).inserted else {
                throw ExternalWidgetDocumentError.duplicateWidgetID(
                    definition.descriptor.id
                )
            }
            definitions.append(definition)
        }

        return definitions.sorted {
            $0.descriptor.id.rawValue < $1.descriptor.id.rawValue
        }
    }

    private func normalizedWidgetID(
        _ rawValue: String
    ) throws -> WidgetID {
        guard !rawValue.isEmpty,
              rawValue.count <= Self.maximumWidgetIDLength,
              rawValue.hasPrefix("external."),
              !rawValue.hasSuffix("."),
              !rawValue.contains(".."),
              rawValue.unicodeScalars.allSatisfy({ scalar in
                  let value = scalar.value
                  return (value >= 48 && value <= 57)
                      || (value >= 97 && value <= 122)
                      || value == 45
                      || value == 46
                      || value == 95
              }),
              rawValue.dropFirst("external.".count).first.map({
                  let value = $0.unicodeScalars.first?.value ?? 0
                  return (value >= 48 && value <= 57)
                      || (value >= 97 && value <= 122)
              }) == true
        else {
            throw ExternalWidgetDocumentError.invalidWidgetID(rawValue)
        }

        return WidgetID(rawValue: rawValue)
    }

    private func normalizedDisplayName(
        _ rawValue: String
    ) throws -> String {
        let value = rawValue.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        guard !value.isEmpty,
              value.count <= Self.maximumDisplayNameLength,
              isSafeSingleLine(value)
        else {
            throw ExternalWidgetDocumentError.invalidDisplayName
        }
        return value
    }

    private func normalizedRefreshPolicy(
        _ refresh: ExternalWidgetRefresh
    ) throws -> WidgetRefreshPolicy {
        switch refresh.kind {
        case .manual:
            guard refresh.intervalSeconds == nil else {
                throw ExternalWidgetDocumentError.invalidRefreshPolicy
            }
            return .manual

        case .interval:
            guard let interval = refresh.intervalSeconds,
                  interval.isFinite,
                  interval >= Self.minimumRefreshInterval,
                  interval <= Self.maximumRefreshInterval
            else {
                throw ExternalWidgetDocumentError.invalidRefreshPolicy
            }
            return .interval(interval)
        }
    }

    private func normalizedGeneratedAt(
        _ seconds: Double?
    ) throws -> Date {
        let current = now()
        guard let seconds else {
            return current
        }
        guard seconds.isFinite, seconds >= 0 else {
            throw ExternalWidgetDocumentError.invalidGeneratedAt
        }

        let generatedAt = Date(timeIntervalSince1970: seconds)
        guard generatedAt.timeIntervalSince(current)
                <= Self.maximumClockSkew
        else {
            throw ExternalWidgetDocumentError.invalidGeneratedAt
        }
        return generatedAt
    }

    private func normalizedContent(
        _ document: ExternalWidgetContentDocument,
        field: String,
        maximumTextLength: Int
    ) throws -> WidgetContent {
        let text = document.text.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        let accessibilityLabel = document.accessibilityLabel
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard !text.isEmpty,
              text.count <= maximumTextLength,
              isSafeSingleLine(text),
              !accessibilityLabel.isEmpty,
              accessibilityLabel.count
                <= Self.maximumAccessibilityLabelLength,
              isSafeSingleLine(accessibilityLabel)
        else {
            throw ExternalWidgetDocumentError.invalidContent(
                field: field
            )
        }

        let systemImage: String?
        if let rawImage = document.systemImage {
            guard Self.allowedSystemImages.contains(rawImage) else {
                throw ExternalWidgetDocumentError
                    .unsupportedSystemImage(rawImage)
            }
            systemImage = rawImage
        } else {
            systemImage = nil
        }

        return WidgetContent(
            text: text,
            systemImage: systemImage,
            accessibilityLabel: accessibilityLabel
        )
    }

    private func isSafeSingleLine(_ value: String) -> Bool {
        !value.unicodeScalars.contains { scalar in
            CharacterSet.controlCharacters.contains(scalar)
                || CharacterSet.newlines.contains(scalar)
        }
    }

    private func severity(
        _ value: ExternalWidgetSeverity
    ) -> WidgetSeverity {
        switch value {
        case .nominal: .nominal
        case .active: .active
        case .attention: .attention
        case .critical: .critical
        case .unavailable: .unavailable
        }
    }

    private func priority(
        _ value: ExternalWidgetPriority
    ) -> WidgetPriority {
        switch value {
        case .background: .background
        case .normal: .normal
        case .attention: .attention
        case .critical: .critical
        }
    }
}

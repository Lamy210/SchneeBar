import Foundation

public enum ExternalWidgetRepresentation: String, Codable, Equatable, Sendable {
    case compact
    case normal
    case critical
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

public enum ExternalWidgetVisibilityKind: String, Codable, Equatable, Sendable {
    case always
    case whenNotNominal
    case minimumSeverity
}

public enum ExternalWidgetRefreshKind: String, Codable, Equatable, Sendable {
    case manual
    case interval
    case adaptive
}

public struct ExternalWidgetVisibilityDocument:
    Codable,
    Equatable,
    Sendable
{
    public let kind: ExternalWidgetVisibilityKind
    public let minimumSeverity: ExternalWidgetSeverity?

    public init(
        kind: ExternalWidgetVisibilityKind,
        minimumSeverity: ExternalWidgetSeverity? = nil
    ) {
        self.kind = kind
        self.minimumSeverity = minimumSeverity
    }

    private enum CodingKeys: String, CodingKey {
        case kind
        case minimumSeverity
    }

    public init(from decoder: Decoder) throws {
        try rejectUnknownKeys(
            decoder,
            allowed: [
                CodingKeys.kind.stringValue,
                CodingKeys.minimumSeverity.stringValue,
            ]
        )
        let container = try decoder.container(keyedBy: CodingKeys.self)
        kind = try container.decode(
            ExternalWidgetVisibilityKind.self,
            forKey: .kind
        )
        minimumSeverity = try container.decodeIfPresent(
            ExternalWidgetSeverity.self,
            forKey: .minimumSeverity
        )
    }
}

public struct ExternalWidgetRefreshDocument:
    Codable,
    Equatable,
    Sendable
{
    public let kind: ExternalWidgetRefreshKind
    public let intervalSeconds: Double?
    public let activeSeconds: Double?
    public let idleSeconds: Double?

    public init(
        kind: ExternalWidgetRefreshKind,
        intervalSeconds: Double? = nil,
        activeSeconds: Double? = nil,
        idleSeconds: Double? = nil
    ) {
        self.kind = kind
        self.intervalSeconds = intervalSeconds
        self.activeSeconds = activeSeconds
        self.idleSeconds = idleSeconds
    }

    private enum CodingKeys: String, CodingKey {
        case kind
        case intervalSeconds
        case activeSeconds
        case idleSeconds
    }

    public init(from decoder: Decoder) throws {
        try rejectUnknownKeys(
            decoder,
            allowed: [
                CodingKeys.kind.stringValue,
                CodingKeys.intervalSeconds.stringValue,
                CodingKeys.activeSeconds.stringValue,
                CodingKeys.idleSeconds.stringValue,
            ]
        )
        let container = try decoder.container(keyedBy: CodingKeys.self)
        kind = try container.decode(
            ExternalWidgetRefreshKind.self,
            forKey: .kind
        )
        intervalSeconds = try container.decodeIfPresent(
            Double.self,
            forKey: .intervalSeconds
        )
        activeSeconds = try container.decodeIfPresent(
            Double.self,
            forKey: .activeSeconds
        )
        idleSeconds = try container.decodeIfPresent(
            Double.self,
            forKey: .idleSeconds
        )
    }
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

    private enum CodingKeys: String, CodingKey {
        case text
        case systemImage
        case accessibilityLabel
    }

    public init(from decoder: Decoder) throws {
        try rejectUnknownKeys(
            decoder,
            allowed: [
                CodingKeys.text.stringValue,
                CodingKeys.systemImage.stringValue,
                CodingKeys.accessibilityLabel.stringValue,
            ]
        )
        let container = try decoder.container(keyedBy: CodingKeys.self)
        text = try container.decode(String.self, forKey: .text)
        systemImage = try container.decodeIfPresent(
            String.self,
            forKey: .systemImage
        )
        accessibilityLabel = try container.decode(
            String.self,
            forKey: .accessibilityLabel
        )
    }
}

public struct ExternalWidgetSnapshotDocument:
    Codable,
    Equatable,
    Sendable
{
    public let severity: ExternalWidgetSeverity
    public let priority: ExternalWidgetPriority
    public let generatedAtUnixSeconds: Double?
    public let compact: ExternalWidgetContentDocument
    public let normal: ExternalWidgetContentDocument
    public let critical: ExternalWidgetContentDocument?

    public init(
        severity: ExternalWidgetSeverity,
        priority: ExternalWidgetPriority,
        generatedAtUnixSeconds: Double? = nil,
        compact: ExternalWidgetContentDocument,
        normal: ExternalWidgetContentDocument,
        critical: ExternalWidgetContentDocument? = nil
    ) {
        self.severity = severity
        self.priority = priority
        self.generatedAtUnixSeconds = generatedAtUnixSeconds
        self.compact = compact
        self.normal = normal
        self.critical = critical
    }

    private enum CodingKeys: String, CodingKey {
        case severity
        case priority
        case generatedAtUnixSeconds
        case compact
        case normal
        case critical
    }

    public init(from decoder: Decoder) throws {
        try rejectUnknownKeys(
            decoder,
            allowed: [
                CodingKeys.severity.stringValue,
                CodingKeys.priority.stringValue,
                CodingKeys.generatedAtUnixSeconds.stringValue,
                CodingKeys.compact.stringValue,
                CodingKeys.normal.stringValue,
                CodingKeys.critical.stringValue,
            ]
        )
        let container = try decoder.container(keyedBy: CodingKeys.self)
        severity = try container.decode(
            ExternalWidgetSeverity.self,
            forKey: .severity
        )
        priority = try container.decode(
            ExternalWidgetPriority.self,
            forKey: .priority
        )
        generatedAtUnixSeconds = try container.decodeIfPresent(
            Double.self,
            forKey: .generatedAtUnixSeconds
        )
        compact = try container.decode(
            ExternalWidgetContentDocument.self,
            forKey: .compact
        )
        normal = try container.decode(
            ExternalWidgetContentDocument.self,
            forKey: .normal
        )
        critical = try container.decodeIfPresent(
            ExternalWidgetContentDocument.self,
            forKey: .critical
        )
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
    public let defaultEnabled: Bool
    public let defaultOrder: Int
    public let defaultRepresentation: ExternalWidgetRepresentation
    public let visibility: ExternalWidgetVisibilityDocument
    public let refresh: ExternalWidgetRefreshDocument
    public let snapshot: ExternalWidgetSnapshotDocument

    public init(
        schemaVersion: Int,
        id: String,
        displayName: String,
        defaultEnabled: Bool,
        defaultOrder: Int,
        defaultRepresentation: ExternalWidgetRepresentation,
        visibility: ExternalWidgetVisibilityDocument,
        refresh: ExternalWidgetRefreshDocument,
        snapshot: ExternalWidgetSnapshotDocument
    ) {
        self.schemaVersion = schemaVersion
        self.id = id
        self.displayName = displayName
        self.defaultEnabled = defaultEnabled
        self.defaultOrder = defaultOrder
        self.defaultRepresentation = defaultRepresentation
        self.visibility = visibility
        self.refresh = refresh
        self.snapshot = snapshot
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion
        case id
        case displayName
        case defaultEnabled
        case defaultOrder
        case defaultRepresentation
        case visibility
        case refresh
        case snapshot
    }

    public init(from decoder: Decoder) throws {
        try rejectUnknownKeys(
            decoder,
            allowed: [
                CodingKeys.schemaVersion.stringValue,
                CodingKeys.id.stringValue,
                CodingKeys.displayName.stringValue,
                CodingKeys.defaultEnabled.stringValue,
                CodingKeys.defaultOrder.stringValue,
                CodingKeys.defaultRepresentation.stringValue,
                CodingKeys.visibility.stringValue,
                CodingKeys.refresh.stringValue,
                CodingKeys.snapshot.stringValue,
            ]
        )
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try container.decode(Int.self, forKey: .schemaVersion)
        id = try container.decode(String.self, forKey: .id)
        displayName = try container.decode(String.self, forKey: .displayName)
        defaultEnabled = try container.decode(
            Bool.self,
            forKey: .defaultEnabled
        )
        defaultOrder = try container.decode(Int.self, forKey: .defaultOrder)
        defaultRepresentation = try container.decode(
            ExternalWidgetRepresentation.self,
            forKey: .defaultRepresentation
        )
        visibility = try container.decode(
            ExternalWidgetVisibilityDocument.self,
            forKey: .visibility
        )
        refresh = try container.decode(
            ExternalWidgetRefreshDocument.self,
            forKey: .refresh
        )
        snapshot = try container.decode(
            ExternalWidgetSnapshotDocument.self,
            forKey: .snapshot
        )
    }
}

private struct ExternalWidgetAnyCodingKey: CodingKey {
    let stringValue: String
    let intValue: Int?

    init?(stringValue: String) {
        self.stringValue = stringValue
        intValue = nil
    }

    init?(intValue: Int) {
        stringValue = String(intValue)
        self.intValue = intValue
    }
}

private func rejectUnknownKeys(
    _ decoder: Decoder,
    allowed: Set<String>
) throws {
    let container = try decoder.container(
        keyedBy: ExternalWidgetAnyCodingKey.self
    )
    let unknown = container.allKeys
        .map(\.stringValue)
        .filter { !allowed.contains($0) }
        .sorted()

    guard let first = unknown.first else {
        return
    }

    throw DecodingError.dataCorrupted(
        DecodingError.Context(
            codingPath: decoder.codingPath,
            debugDescription: "Unsupported external-widget key: \(first)"
        )
    )
}

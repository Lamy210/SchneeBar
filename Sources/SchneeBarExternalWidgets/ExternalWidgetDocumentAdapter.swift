import Foundation
import SchneeBarCore

public enum ExternalWidgetContentSlot: Equatable, Sendable {
    case compact
    case normal
    case critical
}

public enum ExternalWidgetDocumentError: Error, Equatable, Sendable {
    case unsupportedSchemaVersion(Int)
    case invalidID
    case invalidDisplayName
    case defaultEnablementNotAllowed
    case invalidDefaultOrder
    case invalidVisibilityPolicy
    case invalidRefreshPolicy
    case invalidGeneratedAt
    case invalidContent(ExternalWidgetContentSlot)
    case unsupportedSystemImage
    case duplicateID(WidgetID)
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

public struct ExternalWidgetDocumentAdapter: Sendable {
    private static let supportedSchemaVersion = 1
    private static let minimumDefaultOrder = 1_000
    private static let maximumDefaultOrder = 10_000
    private static let minimumRefreshSeconds: TimeInterval = 5
    private static let maximumRefreshSeconds: TimeInterval = 3_600
    private static let maximumGeneratedAtUnixSeconds: TimeInterval = 4_102_444_800

    private static let allowedSystemImages: Set<String> = [
        "antenna.radiowaves.left.and.right",
        "bolt.fill",
        "checkmark.circle",
        "checkmark.circle.fill",
        "clock",
        "cpu",
        "exclamationmark.triangle",
        "exclamationmark.triangle.fill",
        "externaldrive.fill",
        "hammer",
        "info.circle",
        "memorychip",
        "network",
        "questionmark.circle",
        "server.rack",
        "xmark.circle",
        "xmark.circle.fill",
    ]

    public init() {}

    public func normalize(
        _ document: ExternalWidgetDocument,
        now: Date = .now
    ) throws -> ExternalWidgetDefinition {
        let widgetID = try validatedWidgetID(document)

        let displayName = try normalizedBoundedString(
            document.displayName,
            maximumCharacters: 64,
            maximumUTF8Bytes: 256,
            error: .invalidDisplayName
        )

        guard !document.defaultEnabled else {
            throw ExternalWidgetDocumentError.defaultEnablementNotAllowed
        }
        guard (Self.minimumDefaultOrder ... Self.maximumDefaultOrder)
            .contains(document.defaultOrder)
        else {
            throw ExternalWidgetDocumentError.invalidDefaultOrder
        }

        let descriptor = WidgetDescriptor(
            id: widgetID,
            displayName: displayName,
            defaultIsEnabled: false,
            defaultOrder: document.defaultOrder,
            defaultRepresentation: document.defaultRepresentation.coreValue,
            visibilityPolicy: try visibilityPolicy(document.visibility),
            refreshPolicy: try refreshPolicy(document.refresh)
        )

        let generatedAt = try generatedAt(
            document.snapshot.generatedAtUnixSeconds,
            now: now
        )
        let compact = try content(
            document.snapshot.compact,
            slot: .compact
        )
        let normal = try content(
            document.snapshot.normal,
            slot: .normal
        )
        let critical = try document.snapshot.critical.map {
            try content($0, slot: .critical)
        }

        let snapshot = WidgetSnapshot(
            descriptor: descriptor,
            generatedAt: generatedAt,
            severity: document.snapshot.severity.coreValue,
            priority: document.snapshot.priority.coreValue,
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

    public func normalizeCollection(
        _ documents: [ExternalWidgetDocument],
        now: Date = .now
    ) throws -> [ExternalWidgetDefinition] {
        var seen = Set<WidgetID>()
        for document in documents {
            let id = try validatedWidgetID(document)
            guard seen.insert(id).inserted else {
                throw ExternalWidgetDocumentError.duplicateID(id)
            }
        }

        let normalized = try documents.map {
            try normalize($0, now: now)
        }

        return normalized.sorted {
            $0.descriptor.id.rawValue < $1.descriptor.id.rawValue
        }
    }

    private func validatedWidgetID(
        _ document: ExternalWidgetDocument
    ) throws -> WidgetID {
        guard document.schemaVersion == Self.supportedSchemaVersion else {
            throw ExternalWidgetDocumentError.unsupportedSchemaVersion(
                document.schemaVersion
            )
        }
        guard isValidExternalID(document.id) else {
            throw ExternalWidgetDocumentError.invalidID
        }
        return WidgetID(rawValue: document.id)
    }

    private func isValidExternalID(_ rawValue: String) -> Bool {
        guard rawValue.utf8.count <= 96 else {
            return false
        }

        let segments = rawValue.split(
            separator: ".",
            omittingEmptySubsequences: false
        )
        guard segments.count >= 2,
              segments.first == "external"
        else {
            return false
        }

        return segments.dropFirst().allSatisfy { segment in
            guard !segment.isEmpty else {
                return false
            }
            return segment.unicodeScalars.allSatisfy { scalar in
                let value = scalar.value
                return (value >= 48 && value <= 57)
                    || (value >= 97 && value <= 122)
                    || value == 95
            }
        }
    }

    private func visibilityPolicy(
        _ document: ExternalWidgetVisibilityDocument
    ) throws -> WidgetVisibilityPolicy {
        switch document.kind {
        case .always:
            guard document.minimumSeverity == nil else {
                throw ExternalWidgetDocumentError.invalidVisibilityPolicy
            }
            return .always
        case .whenNotNominal:
            guard document.minimumSeverity == nil else {
                throw ExternalWidgetDocumentError.invalidVisibilityPolicy
            }
            return .whenNotNominal
        case .minimumSeverity:
            guard let severity = document.minimumSeverity else {
                throw ExternalWidgetDocumentError.invalidVisibilityPolicy
            }
            return .minimumSeverity(severity.coreValue)
        }
    }

    private func refreshPolicy(
        _ document: ExternalWidgetRefreshDocument
    ) throws -> WidgetRefreshPolicy {
        switch document.kind {
        case .manual:
            guard document.intervalSeconds == nil,
                  document.activeSeconds == nil,
                  document.idleSeconds == nil
            else {
                throw ExternalWidgetDocumentError.invalidRefreshPolicy
            }
            return .manual
        case .interval:
            guard let interval = document.intervalSeconds,
                  document.activeSeconds == nil,
                  document.idleSeconds == nil,
                  isValidRefreshInterval(interval)
            else {
                throw ExternalWidgetDocumentError.invalidRefreshPolicy
            }
            return .interval(interval)
        case .adaptive:
            guard document.intervalSeconds == nil,
                  let active = document.activeSeconds,
                  let idle = document.idleSeconds,
                  isValidRefreshInterval(active),
                  isValidRefreshInterval(idle),
                  active <= idle
            else {
                throw ExternalWidgetDocumentError.invalidRefreshPolicy
            }
            return .adaptive(active: active, idle: idle)
        }
    }

    private func isValidRefreshInterval(_ value: TimeInterval) -> Bool {
        value.isFinite
            && (Self.minimumRefreshSeconds ... Self.maximumRefreshSeconds)
                .contains(value)
    }

    private func generatedAt(
        _ unixSeconds: Double?,
        now: Date
    ) throws -> Date {
        guard let unixSeconds else {
            return now
        }
        guard unixSeconds.isFinite,
              (0 ... Self.maximumGeneratedAtUnixSeconds)
                .contains(unixSeconds)
        else {
            throw ExternalWidgetDocumentError.invalidGeneratedAt
        }
        return Date(timeIntervalSince1970: unixSeconds)
    }

    private func content(
        _ document: ExternalWidgetContentDocument,
        slot: ExternalWidgetContentSlot
    ) throws -> WidgetContent {
        let maximumTextCharacters: Int
        let maximumTextBytes: Int
        switch slot {
        case .compact:
            maximumTextCharacters = 32
            maximumTextBytes = 128
        case .normal, .critical:
            maximumTextCharacters = 128
            maximumTextBytes = 512
        }

        let text: String
        do {
            text = try normalizedBoundedString(
                document.text,
                maximumCharacters: maximumTextCharacters,
                maximumUTF8Bytes: maximumTextBytes,
                error: .invalidContent(slot)
            )
        } catch {
            throw ExternalWidgetDocumentError.invalidContent(slot)
        }

        let accessibilityLabel: String
        do {
            accessibilityLabel = try normalizedBoundedString(
                document.accessibilityLabel,
                maximumCharacters: 160,
                maximumUTF8Bytes: 640,
                error: .invalidContent(slot)
            )
        } catch {
            throw ExternalWidgetDocumentError.invalidContent(slot)
        }

        if let systemImage = document.systemImage {
            guard !systemImage.unicodeScalars.contains(where: {
                CharacterSet.controlCharacters.contains($0)
            }),
            systemImage.utf8.count <= 64,
            Self.allowedSystemImages.contains(systemImage)
            else {
                throw ExternalWidgetDocumentError.unsupportedSystemImage
            }
        }

        return WidgetContent(
            text: text,
            systemImage: document.systemImage,
            accessibilityLabel: accessibilityLabel
        )
    }

    private func normalizedBoundedString(
        _ rawValue: String,
        maximumCharacters: Int,
        maximumUTF8Bytes: Int,
        error: ExternalWidgetDocumentError
    ) throws -> String {
        guard !rawValue.unicodeScalars.contains(where: {
            CharacterSet.controlCharacters.contains($0)
        }) else {
            throw error
        }

        let value = rawValue.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        guard !value.isEmpty,
              value.count <= maximumCharacters,
              value.utf8.count <= maximumUTF8Bytes
        else {
            throw error
        }
        return value
    }
}

private extension ExternalWidgetRepresentation {
    var coreValue: WidgetRepresentationKind {
        switch self {
        case .compact: .compact
        case .normal: .normal
        case .critical: .critical
        }
    }
}

private extension ExternalWidgetSeverity {
    var coreValue: WidgetSeverity {
        switch self {
        case .nominal: .nominal
        case .active: .active
        case .attention: .attention
        case .critical: .critical
        case .unavailable: .unavailable
        }
    }
}

private extension ExternalWidgetPriority {
    var coreValue: WidgetPriority {
        switch self {
        case .background: .background
        case .normal: .normal
        case .attention: .attention
        case .critical: .critical
        }
    }
}

import Foundation

public struct WidgetID: RawRepresentable, Hashable, Codable, Sendable, ExpressibleByStringLiteral {
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    public init(stringLiteral value: String) {
        rawValue = value
    }
}

public enum WidgetSeverity: Int, Codable, Comparable, Sendable {
    case nominal = 0
    case active = 10
    case attention = 20
    case critical = 30
    case unavailable = 40

    public static func < (lhs: WidgetSeverity, rhs: WidgetSeverity) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

public enum WidgetPriority: Int, Codable, Comparable, Sendable {
    case background = 0
    case normal = 100
    case attention = 200
    case critical = 300

    public static func < (lhs: WidgetPriority, rhs: WidgetPriority) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

public enum WidgetRepresentationKind: String, Codable, CaseIterable, Sendable {
    case compact
    case normal
    case critical
}

public struct WidgetContent: Equatable, Sendable {
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

public struct WidgetRepresentations: Equatable, Sendable {
    public let compact: WidgetContent
    public let normal: WidgetContent
    public let critical: WidgetContent?

    public init(
        compact: WidgetContent,
        normal: WidgetContent,
        critical: WidgetContent? = nil
    ) {
        self.compact = compact
        self.normal = normal
        self.critical = critical
    }

    public func content(for kind: WidgetRepresentationKind) -> WidgetContent {
        switch kind {
        case .compact:
            compact
        case .normal:
            normal
        case .critical:
            critical ?? normal
        }
    }
}

public enum WidgetVisibilityPolicy: Equatable, Sendable {
    case always
    case whenNotNominal
    case minimumSeverity(WidgetSeverity)

    public func isVisible(for severity: WidgetSeverity) -> Bool {
        switch self {
        case .always:
            true
        case .whenNotNominal:
            severity != .nominal
        case let .minimumSeverity(minimum):
            severity >= minimum
        }
    }
}

public enum WidgetRefreshPolicy: Equatable, Sendable {
    case manual
    case interval(TimeInterval)
    case adaptive(active: TimeInterval, idle: TimeInterval)

    public func interval(for severity: WidgetSeverity) -> TimeInterval? {
        switch self {
        case .manual:
            nil
        case let .interval(interval):
            interval
        case let .adaptive(active, idle):
            severity >= .active ? active : idle
        }
    }
}

public struct WidgetDescriptor: Equatable, Sendable {
    public let id: WidgetID
    public let displayName: String
    public let defaultRepresentation: WidgetRepresentationKind
    public let visibilityPolicy: WidgetVisibilityPolicy
    public let refreshPolicy: WidgetRefreshPolicy

    public init(
        id: WidgetID,
        displayName: String,
        defaultRepresentation: WidgetRepresentationKind = .normal,
        visibilityPolicy: WidgetVisibilityPolicy = .always,
        refreshPolicy: WidgetRefreshPolicy = .manual
    ) {
        self.id = id
        self.displayName = displayName
        self.defaultRepresentation = defaultRepresentation
        self.visibilityPolicy = visibilityPolicy
        self.refreshPolicy = refreshPolicy
    }
}

public struct WidgetSnapshot: Equatable, Sendable {
    public let descriptor: WidgetDescriptor
    public let generatedAt: Date
    public let severity: WidgetSeverity
    public let priority: WidgetPriority
    public let representations: WidgetRepresentations

    public init(
        descriptor: WidgetDescriptor,
        generatedAt: Date = .now,
        severity: WidgetSeverity,
        priority: WidgetPriority,
        representations: WidgetRepresentations
    ) {
        self.descriptor = descriptor
        self.generatedAt = generatedAt
        self.severity = severity
        self.priority = priority
        self.representations = representations
    }

    public var isVisible: Bool {
        descriptor.visibilityPolicy.isVisible(for: severity)
    }

    public func content(for kind: WidgetRepresentationKind? = nil) -> WidgetContent {
        representations.content(for: kind ?? descriptor.defaultRepresentation)
    }
}

public protocol WidgetProvider: Sendable {
    var descriptor: WidgetDescriptor { get }
    func snapshot() async throws -> WidgetSnapshot
}

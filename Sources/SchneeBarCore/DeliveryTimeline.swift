import Foundation

public enum DeliveryTimelineConfidence: String, Codable, CaseIterable, Sendable {
    case exact
    case high
    case medium
    case unknown
}

public enum DeliveryTimelineEventKind: String, Codable, CaseIterable, Sendable {
    case pullRequest
    case merge
    case execution
    case deployment
}

public enum DeliveryTimelineStatus: String, Codable, CaseIterable, Sendable {
    case correlated
    case evidenceUnavailable
    case temporarilyUnavailable
}

public enum DeliveryTimelineEvidenceState: String, Codable, CaseIterable, Sendable {
    case confirmed
    case missing
    case unavailable
}

public struct DeliveryTimelineEvidenceItem: Identifiable, Equatable, Sendable {
    public let id: String
    public let title: String
    public let detail: String?
    public let state: DeliveryTimelineEvidenceState

    public init(
        id: String,
        title: String,
        detail: String? = nil,
        state: DeliveryTimelineEvidenceState
    ) {
        self.id = id
        self.title = title
        self.detail = detail
        self.state = state
    }
}

public struct DeliveryTimelineEvent: Identifiable, Equatable, Sendable {
    public let id: String
    public let kind: DeliveryTimelineEventKind
    public let title: String
    public let detail: String?
    public let state: ActivityDetailState
    public let destinationURL: URL?
    public let occurredAt: Date?

    public init(
        id: String,
        kind: DeliveryTimelineEventKind,
        title: String,
        detail: String? = nil,
        state: ActivityDetailState,
        destinationURL: URL? = nil,
        occurredAt: Date? = nil
    ) {
        self.id = id
        self.kind = kind
        self.title = title
        self.detail = detail
        self.state = state
        self.destinationURL = destinationURL
        self.occurredAt = occurredAt
    }
}

public struct DeliveryTimelineSnapshot: Equatable, Sendable {
    public let status: DeliveryTimelineStatus
    public let confidence: DeliveryTimelineConfidence
    public let events: [DeliveryTimelineEvent]
    public let evidence: [DeliveryTimelineEvidenceItem]

    public init(
        status: DeliveryTimelineStatus,
        confidence: DeliveryTimelineConfidence,
        events: [DeliveryTimelineEvent],
        evidence: [DeliveryTimelineEvidenceItem] = []
    ) {
        self.status = status
        self.confidence = confidence
        self.events = events
        self.evidence = evidence
    }
}

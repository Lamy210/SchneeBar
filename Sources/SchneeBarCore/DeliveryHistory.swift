import Foundation

public struct DeliveryHistoryEntry: Identifiable, Equatable, Sendable {
    public let id: String
    public let title: String
    public let detail: String?
    public let state: ActivityDetailState
    public let destinationURL: URL?
    public let occurredAt: Date

    public init(
        id: String,
        title: String,
        detail: String? = nil,
        state: ActivityDetailState,
        destinationURL: URL? = nil,
        occurredAt: Date
    ) {
        self.id = id
        self.title = title
        self.detail = detail
        self.state = state
        self.destinationURL = destinationURL
        self.occurredAt = occurredAt
    }
}

public struct DeliveryHistorySnapshot: Equatable, Sendable {
    public let repository: String
    public let entries: [DeliveryHistoryEntry]

    public init(
        repository: String,
        entries: [DeliveryHistoryEntry]
    ) {
        self.repository = repository
        self.entries = entries
    }
}

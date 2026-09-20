import Foundation

public struct DeliveryRecoveryEvent: Identifiable, Equatable, Sendable {
    public let id: String
    public let repository: String
    public let title: String
    public let detail: String
    public let destinationURL: URL?
    public let occurredAt: Date

    public init(
        id: String,
        repository: String,
        title: String,
        detail: String,
        destinationURL: URL? = nil,
        occurredAt: Date
    ) {
        self.id = id
        self.repository = repository
        self.title = title
        self.detail = detail
        self.destinationURL = destinationURL
        self.occurredAt = occurredAt
    }
}

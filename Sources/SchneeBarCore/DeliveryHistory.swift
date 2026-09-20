import Foundation

public struct DeliveryHistoryEntry: Identifiable, Codable, Equatable, Sendable {
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

public struct DeliveryHistorySnapshot: Codable, Equatable, Sendable {
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


public struct DeliveryHistoryStorageScope: Codable, Equatable, Hashable, Sendable {
    public let sourceID: String
    public let repositoryID: String

    public init(
        sourceID: String,
        repositoryID: String
    ) {
        self.sourceID = sourceID
        self.repositoryID = repositoryID
    }
}

public protocol DeliveryHistoryStoring: Sendable {
    func load(
        scope: DeliveryHistoryStorageScope
    ) async throws -> DeliveryHistorySnapshot?

    func save(
        _ snapshot: DeliveryHistorySnapshot,
        scope: DeliveryHistoryStorageScope
    ) async throws

    func delete(sourceID: String) async throws
}

public struct NoopDeliveryHistoryStore: DeliveryHistoryStoring, Sendable {
    public init() {}

    public func load(
        scope: DeliveryHistoryStorageScope
    ) async throws -> DeliveryHistorySnapshot? {
        nil
    }

    public func save(
        _ snapshot: DeliveryHistorySnapshot,
        scope: DeliveryHistoryStorageScope
    ) async throws {}

    public func delete(sourceID: String) async throws {}
}

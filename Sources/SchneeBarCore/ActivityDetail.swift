import Foundation

public enum ActivityDetailState: String, Codable, CaseIterable, Sendable {
    case success
    case running
    case failed
    case waiting
    case neutral
}

public struct ActivityDetailRow: Identifiable, Equatable, Sendable {
    public let id: String
    public let title: String
    public let detail: String?
    public let state: ActivityDetailState
    public let destinationURL: URL?
    public let children: [ActivityDetailRow]

    public init(
        id: String,
        title: String,
        detail: String? = nil,
        state: ActivityDetailState,
        destinationURL: URL? = nil,
        children: [ActivityDetailRow] = []
    ) {
        self.id = id
        self.title = title
        self.detail = detail
        self.state = state
        self.destinationURL = destinationURL
        self.children = children
    }
}

public struct ActivityDetailSnapshot: Identifiable, Equatable, Sendable {
    public let id: String
    public let repository: String
    public let title: String
    public let summary: String
    public let state: ActivityState
    public let destinationURL: URL?
    public let rows: [ActivityDetailRow]

    public init(
        id: String,
        repository: String,
        title: String,
        summary: String,
        state: ActivityState,
        destinationURL: URL? = nil,
        rows: [ActivityDetailRow]
    ) {
        self.id = id
        self.repository = repository
        self.title = title
        self.summary = summary
        self.state = state
        self.destinationURL = destinationURL
        self.rows = rows
    }
}

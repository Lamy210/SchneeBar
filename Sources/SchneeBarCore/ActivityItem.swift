import Foundation

public enum ActivityState: String, Codable, CaseIterable, Sendable {
    case success
    case running
    case failed
    case waiting
}

public struct ActivityItem: Identifiable, Codable, Equatable, Sendable {
    public let id: String
    public let repository: String
    public let context: String
    public let detail: String
    public let state: ActivityState
    public let destinationURL: URL?

    public init(
        id: String,
        repository: String,
        context: String,
        detail: String,
        state: ActivityState,
        destinationURL: URL? = nil
    ) {
        self.id = id
        self.repository = repository
        self.context = context
        self.detail = detail
        self.state = state
        self.destinationURL = destinationURL
    }
}

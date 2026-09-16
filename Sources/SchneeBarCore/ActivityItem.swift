import Foundation

public enum ActivityState: String, Codable, CaseIterable, Sendable {
    case success
    case running
    case failed
    case waiting
}

public enum ActivityKind: String, Codable, CaseIterable, Sendable {
    case workflowRun
    case reviewRequest
    case checkRun
}

public enum ActivityAttention: String, Codable, CaseIterable, Sendable {
    case actionRequired
    case needsAttention
    case active
    case informational
}

public struct ActivityItem: Identifiable, Codable, Equatable, Sendable {
    public let id: String
    public let repository: String
    public let context: String
    public let detail: String
    public let state: ActivityState
    public let destinationURL: URL?
    public let kind: ActivityKind
    public let attention: ActivityAttention
    public let updatedAt: Date?

    public init(
        id: String,
        repository: String,
        context: String,
        detail: String,
        state: ActivityState,
        destinationURL: URL? = nil,
        kind: ActivityKind = .workflowRun,
        attention: ActivityAttention? = nil,
        updatedAt: Date? = nil
    ) {
        self.id = id
        self.repository = repository
        self.context = context
        self.detail = detail
        self.state = state
        self.destinationURL = destinationURL
        self.kind = kind
        self.attention = attention ?? Self.defaultAttention(for: state)
        self.updatedAt = updatedAt
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case repository
        case context
        case detail
        case state
        case destinationURL
        case kind
        case attention
        case updatedAt
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        repository = try container.decode(String.self, forKey: .repository)
        context = try container.decode(String.self, forKey: .context)
        detail = try container.decode(String.self, forKey: .detail)
        state = try container.decode(ActivityState.self, forKey: .state)
        destinationURL = try container.decodeIfPresent(URL.self, forKey: .destinationURL)
        kind = try container.decodeIfPresent(ActivityKind.self, forKey: .kind) ?? .workflowRun
        attention = try container.decodeIfPresent(ActivityAttention.self, forKey: .attention)
            ?? Self.defaultAttention(for: state)
        updatedAt = try container.decodeIfPresent(Date.self, forKey: .updatedAt)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(repository, forKey: .repository)
        try container.encode(context, forKey: .context)
        try container.encode(detail, forKey: .detail)
        try container.encode(state, forKey: .state)
        try container.encodeIfPresent(destinationURL, forKey: .destinationURL)
        try container.encode(kind, forKey: .kind)
        try container.encode(attention, forKey: .attention)
        try container.encodeIfPresent(updatedAt, forKey: .updatedAt)
    }

    private static func defaultAttention(for state: ActivityState) -> ActivityAttention {
        switch state {
        case .failed:
            .needsAttention
        case .running, .waiting:
            .active
        case .success:
            .informational
        }
    }
}

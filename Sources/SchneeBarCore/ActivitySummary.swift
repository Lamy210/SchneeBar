public struct ActivitySummary: Equatable, Sendable {
    public let running: Int
    public let failed: Int
    public let waiting: Int
    public let successful: Int
    public let actionRequired: Int
    public let needsAttention: Int

    public init(items: [ActivityItem]) {
        running = items.count { $0.state == .running }
        failed = items.count { $0.state == .failed }
        waiting = items.count { $0.state == .waiting }
        successful = items.count { $0.state == .success }
        actionRequired = items.count { $0.attention == .actionRequired }
        needsAttention = items.count { $0.attention == .needsAttention }
    }

    public var menuBarLabel: String {
        if actionRequired > 0 {
            return "Action \(actionRequired)"
        }
        if needsAttention > 0 {
            return "Alert \(needsAttention)"
        }
        if running > 0 {
            return "Running \(running)"
        }
        if waiting > 0 {
            return "Waiting \(waiting)"
        }
        return "Clear"
    }
}

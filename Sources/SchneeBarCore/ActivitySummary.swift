public struct ActivitySummary: Equatable, Sendable {
    public let running: Int
    public let failed: Int
    public let waiting: Int
    public let successful: Int

    public init(items: [ActivityItem]) {
        running = items.count { $0.state == .running }
        failed = items.count { $0.state == .failed }
        waiting = items.count { $0.state == .waiting }
        successful = items.count { $0.state == .success }
    }

    public var menuBarLabel: String {
        if failed > 0 {
            return "CI ✕\(failed)"
        }
        if running > 0 {
            return "CI ●\(running)"
        }
        return "CI ✓"
    }
}

import Foundation

public struct ActivitySourceID:
    RawRepresentable,
    Hashable,
    Codable,
    Sendable,
    ExpressibleByStringLiteral
{
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    public init(stringLiteral value: String) {
        rawValue = value
    }
}

public protocol ActivitySource: Sendable {
    var id: ActivitySourceID { get }
    func load() async throws -> [ActivityItem]
}

public struct ClosureActivitySource: ActivitySource {
    public let id: ActivitySourceID
    private let loader: @Sendable () async throws -> [ActivityItem]

    public init(
        id: ActivitySourceID,
        load: @escaping @Sendable () async throws -> [ActivityItem]
    ) {
        self.id = id
        loader = load
    }

    public func load() async throws -> [ActivityItem] {
        try await loader()
    }
}

public enum ActivitySourceHealth: Equatable, Sendable {
    case notLoaded
    case healthy
    case degraded
    case unavailable
}

public struct ActivitySourceDiagnostic: Equatable, Sendable {
    public let sourceID: ActivitySourceID
    public let health: ActivitySourceHealth
    public let consecutiveFailureCount: Int
    public let isServingLastKnownGood: Bool
    public let droppedDuplicateItemCount: Int

    public init(
        sourceID: ActivitySourceID,
        health: ActivitySourceHealth,
        consecutiveFailureCount: Int,
        isServingLastKnownGood: Bool,
        droppedDuplicateItemCount: Int
    ) {
        self.sourceID = sourceID
        self.health = health
        self.consecutiveFailureCount = consecutiveFailureCount
        self.isServingLastKnownGood = isServingLastKnownGood
        self.droppedDuplicateItemCount = droppedDuplicateItemCount
    }
}

/// Provider-neutral aggregation for Developer Activity.
///
/// Each source owns globally stable ActivityItem IDs. If a source violates that
/// contract and collides with an earlier registered source, the earlier source
/// wins deterministically and the collision is surfaced in diagnostics.
public actor ActivitySourceEngine {
    private var sources: [ActivitySourceID: any ActivitySource] = [:]
    private var sourceOrder: [ActivitySourceID] = []
    private var cachedItems: [ActivitySourceID: [ActivityItem]] = [:]
    private var attemptedSources: Set<ActivitySourceID> = []
    private var consecutiveFailureCount: [ActivitySourceID: Int] = [:]
    private var duplicateCounts: [ActivitySourceID: Int] = [:]
    private let ordering: ActivityInboxOrdering

    public init(
        sources: [any ActivitySource] = [],
        ordering: ActivityInboxOrdering = ActivityInboxOrdering()
    ) {
        self.ordering = ordering

        for source in sources {
            if self.sources[source.id] == nil {
                sourceOrder.append(source.id)
            }
            self.sources[source.id] = source
        }
    }

    public func register(_ source: any ActivitySource) {
        let id = source.id
        if sources[id] == nil {
            sourceOrder.append(id)
        }
        sources[id] = source
        resetRuntimeState(for: id)
    }

    public func unregister(id: ActivitySourceID) {
        sources.removeValue(forKey: id)
        sourceOrder.removeAll { $0 == id }
        resetRuntimeState(for: id)
    }

    public func sourceIDs() -> [ActivitySourceID] {
        sourceOrder.filter { sources[$0] != nil }
    }

    @discardableResult
    public func loadAll() async -> [ActivityItem] {
        let activeSources = sourceOrder.compactMap { id -> (ActivitySourceID, any ActivitySource)? in
            guard let source = sources[id] else { return nil }
            return (id, source)
        }

        let outcomes = await withTaskGroup(
            of: ActivitySourceLoadOutcome.self,
            returning: [ActivitySourceLoadOutcome].self
        ) { group in
            for (id, source) in activeSources {
                group.addTask {
                    do {
                        return .success(id, try await source.load())
                    } catch is CancellationError {
                        return .cancelled(id)
                    } catch {
                        return .failure(id)
                    }
                }
            }

            var results: [ActivitySourceLoadOutcome] = []
            for await result in group {
                results.append(result)
            }
            return results
        }

        for outcome in outcomes {
            switch outcome {
            case let .success(id, items):
                guard sources[id] != nil else { continue }
                attemptedSources.insert(id)
                cachedItems[id] = items
                consecutiveFailureCount[id] = 0

            case let .failure(id):
                guard sources[id] != nil else { continue }
                attemptedSources.insert(id)
                consecutiveFailureCount[id, default: 0] += 1

            case .cancelled:
                break
            }
        }

        return rebuildAggregate()
    }

    public func currentItems() -> [ActivityItem] {
        rebuildAggregate()
    }

    public func diagnostics() -> [ActivitySourceDiagnostic] {
        sourceOrder.compactMap { id in
            guard sources[id] != nil else { return nil }

            let failures = consecutiveFailureCount[id, default: 0]
            let hasCachedItems = cachedItems[id] != nil
            let health: ActivitySourceHealth

            if !attemptedSources.contains(id) {
                health = .notLoaded
            } else if failures == 0 {
                health = .healthy
            } else if hasCachedItems {
                health = .degraded
            } else {
                health = .unavailable
            }

            return ActivitySourceDiagnostic(
                sourceID: id,
                health: health,
                consecutiveFailureCount: failures,
                isServingLastKnownGood: failures > 0 && hasCachedItems,
                droppedDuplicateItemCount: duplicateCounts[id, default: 0]
            )
        }
    }

    private func resetRuntimeState(for id: ActivitySourceID) {
        cachedItems.removeValue(forKey: id)
        attemptedSources.remove(id)
        consecutiveFailureCount.removeValue(forKey: id)
        duplicateCounts.removeValue(forKey: id)
        _ = rebuildAggregate()
    }

    @discardableResult
    private func rebuildAggregate() -> [ActivityItem] {
        var seenIDs = Set<String>()
        var items: [ActivityItem] = []
        var newDuplicateCounts: [ActivitySourceID: Int] = [:]

        for sourceID in sourceOrder where sources[sourceID] != nil {
            for item in cachedItems[sourceID] ?? [] {
                if seenIDs.insert(item.id).inserted {
                    items.append(item)
                } else {
                    newDuplicateCounts[sourceID, default: 0] += 1
                }
            }
        }

        duplicateCounts = newDuplicateCounts
        return items.sorted(by: ordering.areInIncreasingOrder)
    }
}

private enum ActivitySourceLoadOutcome: Sendable {
    case success(ActivitySourceID, [ActivityItem])
    case failure(ActivitySourceID)
    case cancelled(ActivitySourceID)
}

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

    public static let maximumNamespaceUTF8Bytes = 64
    public static let maximumItemIDUTF8Bytes = 256

    public var isValidNamespace: Bool {
        guard !rawValue.isEmpty,
              rawValue.utf8.count <= Self.maximumNamespaceUTF8Bytes
        else {
            return false
        }
        return rawValue.unicodeScalars.allSatisfy { scalar in
            let value = scalar.value
            return (value >= 48 && value <= 57)
                || (value >= 97 && value <= 122)
                || value == 46
                || value == 95
        }
    }

    public func owns(itemID: String) -> Bool {
        guard isValidNamespace,
              itemID.utf8.count <= Self.maximumItemIDUTF8Bytes,
              !itemID.unicodeScalars.contains(where: {
                  CharacterSet.controlCharacters.contains($0)
              }),
              let separator = itemID.firstIndex(where: {
                  $0 == "-" || $0 == ":"
              }),
              itemID[..<separator] == rawValue[...]
        else {
            return false
        }

        let payloadStart = itemID.index(after: separator)
        return payloadStart < itemID.endIndex
    }
}

public enum ActivitySourceStatus: Equatable, Sendable {
    case available
    case authenticationRequired
    case temporarilyUnavailable
}

public enum ActivitySourceCollectionPolicy {
    public static let maximumSources = 16
    public static let maximumItemsPerSource = 2_048
    public static let maximumAggregateItems = 4_096
}

public struct ActivitySourceSnapshot: Equatable, Sendable {
    public let items: [ActivityItem]
    public let status: ActivitySourceStatus
    public let isTruncated: Bool

    public init(
        items: [ActivityItem],
        status: ActivitySourceStatus,
        isTruncated: Bool = false
    ) {
        self.items = items
        self.status = status
        self.isTruncated = isTruncated
    }

    public static func bounded(
        items: [ActivityItem],
        status: ActivitySourceStatus
    ) -> ActivitySourceSnapshot {
        let ordered = items.sorted(
            by: ActivityInboxOrdering().areInIncreasingOrder
        )
        let maximum = ActivitySourceCollectionPolicy
            .maximumItemsPerSource
        return ActivitySourceSnapshot(
            items: Array(ordered.prefix(maximum)),
            status: status,
            isTruncated: ordered.count > maximum
        )
    }

    public static var unavailable: ActivitySourceSnapshot {
        ActivitySourceSnapshot(
            items: [],
            status: .temporarilyUnavailable
        )
    }
}

public protocol ActivitySource: Sendable {
    var id: ActivitySourceID { get }
    func snapshot() async throws -> ActivitySourceSnapshot
}

public struct ClosureActivitySource: ActivitySource, Sendable {
    public let id: ActivitySourceID
    private let loadSnapshot:
        @Sendable () async throws -> ActivitySourceSnapshot

    public init(
        id: ActivitySourceID,
        loadSnapshot:
            @escaping @Sendable () async throws -> ActivitySourceSnapshot
    ) {
        self.id = id
        self.loadSnapshot = loadSnapshot
    }

    public func snapshot() async throws -> ActivitySourceSnapshot {
        try await loadSnapshot()
    }
}

public struct ActivitySourceStatusRecord: Equatable, Sendable {
    public let sourceID: ActivitySourceID
    public let status: ActivitySourceStatus
    public let isTruncated: Bool

    public init(
        sourceID: ActivitySourceID,
        status: ActivitySourceStatus,
        isTruncated: Bool = false
    ) {
        self.sourceID = sourceID
        self.status = status
        self.isTruncated = isTruncated
    }
}

public struct ActivityAggregateSnapshot: Equatable, Sendable {
    public let items: [ActivityItem]
    public let sources: [ActivitySourceStatusRecord]
    public let isTruncated: Bool

    public init(
        items: [ActivityItem],
        sources: [ActivitySourceStatusRecord],
        isTruncated: Bool = false
    ) {
        self.items = items
        self.sources = sources
        self.isTruncated = isTruncated
    }
}

public enum ActivitySourceAggregationError: Error, Equatable, Sendable {
    case tooManySources
    case sourceItemLimitExceeded(sourceID: ActivitySourceID)
    case invalidSourceID
    case duplicateSourceID(ActivitySourceID)
    case invalidItemNamespace(sourceID: ActivitySourceID)
    case invalidItemTimestamp(sourceID: ActivitySourceID)
    case invalidDestinationURL(sourceID: ActivitySourceID)
    case invalidItemPresentation(sourceID: ActivitySourceID)
    case duplicateItemID(sourceID: ActivitySourceID)
    case noUsableSources([ActivitySourceStatusRecord])
}

public struct ActivitySourceAggregator: Sendable {
    private let registrations: [RegisteredActivitySource]

    public init(sources: [any ActivitySource]) {
        registrations = sources.map(RegisteredActivitySource.init)
    }

    public func load() async throws -> ActivityAggregateSnapshot {
        try Task.checkCancellation()
        guard registrations.count
            <= ActivitySourceCollectionPolicy.maximumSources
        else {
            throw ActivitySourceAggregationError.tooManySources
        }

        var seenSourceIDs = Set<ActivitySourceID>()
        for registration in registrations {
            guard registration.id.isValidNamespace else {
                throw ActivitySourceAggregationError.invalidSourceID
            }
            guard seenSourceIDs.insert(registration.id).inserted else {
                throw ActivitySourceAggregationError.duplicateSourceID(
                    registration.id
                )
            }
        }

        let loaded = try await withThrowingTaskGroup(
            of: LoadedActivitySource.self,
            returning: [LoadedActivitySource].self
        ) { group in
            for registration in registrations {
                group.addTask {
                    do {
                        try Task.checkCancellation()
                        let snapshot = try await registration.source.snapshot()
                        try Task.checkCancellation()
                        return LoadedActivitySource(
                            id: registration.id,
                            snapshot: snapshot
                        )
                    } catch is CancellationError {
                        throw CancellationError()
                    } catch {
                        return LoadedActivitySource(
                            id: registration.id,
                            snapshot: .unavailable
                        )
                    }
                }
            }

            var results: [LoadedActivitySource] = []
            results.reserveCapacity(registrations.count)
            for try await result in group {
                results.append(result)
            }
            try Task.checkCancellation()
            return results.sorted {
                $0.id.rawValue < $1.id.rawValue
            }
        }

        try Task.checkCancellation()
        for source in loaded
        where source.snapshot.items.count
            > ActivitySourceCollectionPolicy.maximumItemsPerSource
        {
            throw ActivitySourceAggregationError.sourceItemLimitExceeded(
                sourceID: source.id
            )
        }

        let statuses = loaded.map {
            ActivitySourceStatusRecord(
                sourceID: $0.id,
                status: $0.snapshot.status,
                isTruncated: $0.snapshot.isTruncated
            )
        }
        let available = loaded.filter {
            $0.snapshot.status == .available
        }

        guard !available.isEmpty else {
            throw ActivitySourceAggregationError.noUsableSources(
                statuses
            )
        }

        var items: [ActivityItem] = []
        var seenItemIDs = Set<String>()
        for source in available {
            for item in source.snapshot.items {
                guard source.id.owns(itemID: item.id) else {
                    throw ActivitySourceAggregationError
                        .invalidItemNamespace(sourceID: source.id)
                }
                guard seenItemIDs.insert(item.id).inserted else {
                    throw ActivitySourceAggregationError
                        .duplicateItemID(sourceID: source.id)
                }
                if let updatedAt = item.updatedAt,
                   !updatedAt.timeIntervalSinceReferenceDate.isFinite
                {
                    throw ActivitySourceAggregationError
                        .invalidItemTimestamp(sourceID: source.id)
                }
                if !ActivityDestinationURLPolicy.allows(
                    item.destinationURL
                ) {
                    throw ActivitySourceAggregationError
                        .invalidDestinationURL(sourceID: source.id)
                }
                guard ActivityPresentationTextPolicy.allows(
                    item.repository,
                    role: .repository
                ),
                ActivityPresentationTextPolicy.allows(
                    item.context,
                    role: .title
                ),
                ActivityPresentationTextPolicy.allows(
                    item.detail,
                    role: .detail
                )
                else {
                    throw ActivitySourceAggregationError
                        .invalidItemPresentation(sourceID: source.id)
                }
                items.append(item)
            }
        }

        let orderedItems = items.sorted(
            by: ActivityInboxOrdering().areInIncreasingOrder
        )
        let maximumAggregateItems = ActivitySourceCollectionPolicy
            .maximumAggregateItems
        let aggregateWasTruncated =
            orderedItems.count > maximumAggregateItems
        let sourceWasTruncated = statuses.contains {
            $0.isTruncated
        }

        return ActivityAggregateSnapshot(
            items: Array(
                orderedItems.prefix(maximumAggregateItems)
            ),
            sources: statuses,
            isTruncated: aggregateWasTruncated || sourceWasTruncated
        )
    }
}

private struct RegisteredActivitySource: Sendable {
    let source: any ActivitySource
    let id: ActivitySourceID

    init(_ source: any ActivitySource) {
        self.source = source
        id = source.id
    }
}

private struct LoadedActivitySource: Sendable {
    let id: ActivitySourceID
    let snapshot: ActivitySourceSnapshot
}

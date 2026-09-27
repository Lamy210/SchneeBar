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

public struct ActivitySourceSnapshot: Equatable, Sendable {
    public let items: [ActivityItem]
    public let status: ActivitySourceStatus

    public init(
        items: [ActivityItem],
        status: ActivitySourceStatus
    ) {
        self.items = items
        self.status = status
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

    public init(
        sourceID: ActivitySourceID,
        status: ActivitySourceStatus
    ) {
        self.sourceID = sourceID
        self.status = status
    }
}

public struct ActivityAggregateSnapshot: Equatable, Sendable {
    public let items: [ActivityItem]
    public let sources: [ActivitySourceStatusRecord]

    public init(
        items: [ActivityItem],
        sources: [ActivitySourceStatusRecord]
    ) {
        self.items = items
        self.sources = sources
    }
}

public enum ActivitySourceAggregationError: Error, Equatable, Sendable {
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

        let statuses = loaded.map {
            ActivitySourceStatusRecord(
                sourceID: $0.id,
                status: $0.snapshot.status
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
                guard Self.hasValidPresentationContent(item) else {
                    throw ActivitySourceAggregationError
                        .invalidItemPresentation(sourceID: source.id)
                }
                items.append(item)
            }
        }

        return ActivityAggregateSnapshot(
            items: items.sorted(
                by: ActivityInboxOrdering().areInIncreasingOrder
            ),
            sources: statuses
        )
    }
    private static func hasValidPresentationContent(
        _ item: ActivityItem
    ) -> Bool {
        isValidPresentationText(
            item.repository,
            maximumCharacters: 512,
            maximumUTF8Bytes: 1_536
        )
            && isValidPresentationText(
                item.context,
                maximumCharacters: 1_024,
                maximumUTF8Bytes: 3_072
            )
            && isValidPresentationText(
                item.detail,
                maximumCharacters: 2_048,
                maximumUTF8Bytes: 6_144
            )
    }

    private static func isValidPresentationText(
        _ value: String,
        maximumCharacters: Int,
        maximumUTF8Bytes: Int
    ) -> Bool {
        guard !value.trimmingCharacters(
            in: .whitespacesAndNewlines
        ).isEmpty,
        value.count <= maximumCharacters,
        value.utf8.count <= maximumUTF8Bytes,
        !value.unicodeScalars.contains(where: {
            CharacterSet.controlCharacters.contains($0)
        })
        else {
            return false
        }
        return true
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

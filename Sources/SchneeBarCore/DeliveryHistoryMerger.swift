import Foundation

public struct DeliveryHistoryMerger: Sendable {
    public let maximumEntries: Int

    public init(maximumEntries: Int = 200) {
        self.maximumEntries = max(1, maximumEntries)
    }

    public func merge(
        cached: DeliveryHistorySnapshot?,
        live: DeliveryHistorySnapshot
    ) -> DeliveryHistorySnapshot {
        mergeSnapshots(
            cached: cached,
            live: live,
            repository: live.repository
        )
    }

    public func resolve(
        cached: DeliveryHistorySnapshot?,
        live: DeliveryHistorySnapshot?
    ) -> DeliveryHistorySnapshot? {
        guard let live else {
            guard let cached else { return nil }
            return bounded(snapshot: cached)
        }
        return merge(
            cached: cached,
            live: live
        )
    }

    private func mergeSnapshots(
        cached: DeliveryHistorySnapshot?,
        live: DeliveryHistorySnapshot,
        repository: String
    ) -> DeliveryHistorySnapshot {
        var entriesByID = Dictionary(
            uniqueKeysWithValues: (cached?.entries ?? []).map { ($0.id, $0) }
        )
        for entry in live.entries {
            entriesByID[entry.id] = entry
        }

        let entries = entriesByID.values
            .sorted(by: entryPrecedes)
            .prefix(maximumEntries)

        return DeliveryHistorySnapshot(
            repository: repository,
            entries: Array(entries)
        )
    }

    private func bounded(
        snapshot: DeliveryHistorySnapshot
    ) -> DeliveryHistorySnapshot {
        DeliveryHistorySnapshot(
            repository: snapshot.repository,
            entries: Array(
                snapshot.entries
                    .sorted(by: entryPrecedes)
                    .prefix(maximumEntries)
            )
        )
    }

    private func entryPrecedes(
        _ lhs: DeliveryHistoryEntry,
        _ rhs: DeliveryHistoryEntry
    ) -> Bool {
        if lhs.occurredAt != rhs.occurredAt {
            return lhs.occurredAt > rhs.occurredAt
        }
        return lhs.id < rhs.id
    }
}

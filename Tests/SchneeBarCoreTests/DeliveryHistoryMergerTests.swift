import Foundation
import SchneeBarCore
import Testing

@Test
func deliveryHistoryMergerCombinesCacheAndLiveWithLiveWinningDuplicates() {
    let cached = DeliveryHistorySnapshot(
        repository: "old/repo",
        entries: [
            historyEntry(id: "same", title: "Cached title", occurredAt: 200),
            historyEntry(id: "old", title: "Old", occurredAt: 100),
        ]
    )
    let live = DeliveryHistorySnapshot(
        repository: "new/repo",
        entries: [
            historyEntry(id: "new", title: "New", occurredAt: 300),
            historyEntry(id: "same", title: "Live title", occurredAt: 200),
        ]
    )

    let merged = DeliveryHistoryMerger(maximumEntries: 200).merge(
        cached: cached,
        live: live
    )

    #expect(merged.repository == "new/repo")
    #expect(merged.entries.map(\.id) == ["new", "same", "old"])
    #expect(merged.entries.first(where: { $0.id == "same" })?.title == "Live title")
}

@Test
func deliveryHistoryMergerSortsEqualTimestampsByID() {
    let date = Date(timeIntervalSince1970: 100)
    let live = DeliveryHistorySnapshot(
        repository: "snow/repo",
        entries: [
            historyEntry(id: "z", title: "Z", occurredAt: date.timeIntervalSince1970),
            historyEntry(id: "a", title: "A", occurredAt: date.timeIntervalSince1970),
        ]
    )

    let merged = DeliveryHistoryMerger(maximumEntries: 200).merge(
        cached: nil,
        live: live
    )

    #expect(merged.entries.map(\.id) == ["a", "z"])
}

@Test
func deliveryHistoryMergerCapsEntries() {
    let live = DeliveryHistorySnapshot(
        repository: "snow/repo",
        entries: (0 ..< 250).map { index in
            historyEntry(
                id: "run-\(index)",
                title: "Run \(index)",
                occurredAt: TimeInterval(index)
            )
        }
    )

    let merged = DeliveryHistoryMerger(maximumEntries: 200).merge(
        cached: nil,
        live: live
    )

    #expect(merged.entries.count == 200)
    #expect(merged.entries.first?.id == "run-249")
    #expect(merged.entries.last?.id == "run-50")
}

@Test
func deliveryHistoryMergerCanReturnCacheWithoutLiveData() throws {
    let cached = DeliveryHistorySnapshot(
        repository: "snow/repo",
        entries: [
            historyEntry(id: "cached", title: "Cached", occurredAt: 100),
        ]
    )

    let merged = try #require(
        DeliveryHistoryMerger(maximumEntries: 200).resolve(
            cached: cached,
            live: nil
        )
    )

    #expect(merged == cached)
}

private func historyEntry(
    id: String,
    title: String,
    occurredAt: TimeInterval
) -> DeliveryHistoryEntry {
    DeliveryHistoryEntry(
        id: id,
        title: title,
        state: .neutral,
        occurredAt: Date(timeIntervalSince1970: occurredAt)
    )
}


@Test
func deliveryHistoryMergerNormalizesDuplicateCachedIDsWithoutTrapping() {
    let cached = DeliveryHistorySnapshot(
        repository: "snow/repo",
        entries: [
            historyEntry(id: "same", title: "Older duplicate", occurredAt: 100),
            historyEntry(id: "same", title: "Later duplicate", occurredAt: 200),
        ]
    )
    let live = DeliveryHistorySnapshot(
        repository: "snow/repo",
        entries: []
    )

    let merged = DeliveryHistoryMerger(maximumEntries: 200).merge(
        cached: cached,
        live: live
    )

    #expect(merged.entries.count == 1)
    #expect(merged.entries[0].id == "same")
    #expect(merged.entries[0].title == "Later duplicate")
}

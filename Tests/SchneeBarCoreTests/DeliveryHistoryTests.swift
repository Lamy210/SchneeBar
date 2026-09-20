import Foundation
import SchneeBarCore
import Testing

@Test
func deliveryHistoryPreservesRepositoryAndEntryOrder() throws {
    let first = DeliveryHistoryEntry(
        id: "github-actions:42:900",
        title: "CI",
        detail: "Succeeded · Default branch · Run #900",
        state: .success,
        destinationURL: try #require(
            URL(string: "https://github.com/snow/repo/actions/runs/900")
        ),
        occurredAt: Date(timeIntervalSince1970: 300)
    )
    let second = DeliveryHistoryEntry(
        id: "github-actions:42:899",
        title: "Release",
        detail: "Failed · release/1.x · Run #899",
        state: .failed,
        destinationURL: try #require(
            URL(string: "https://github.com/snow/repo/actions/runs/899")
        ),
        occurredAt: Date(timeIntervalSince1970: 200)
    )

    let history = DeliveryHistorySnapshot(
        repository: "snow/repo",
        entries: [first, second]
    )

    #expect(history.repository == "snow/repo")
    #expect(history.entries == [first, second])
    #expect(history.entries.map(\.state) == [.success, .failed])
}

@Test
func deliveryHistoryEntryAllowsMissingOptionalPresentationData() {
    let entry = DeliveryHistoryEntry(
        id: "github-actions:42:898",
        title: "CI",
        state: .neutral,
        occurredAt: Date(timeIntervalSince1970: 100)
    )

    #expect(entry.detail == nil)
    #expect(entry.destinationURL == nil)
}

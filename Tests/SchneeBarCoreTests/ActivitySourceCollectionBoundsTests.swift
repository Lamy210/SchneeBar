import Foundation
import SchneeBarCore
import Testing

@Test
func activitySourceSnapshotBoundsLargeInputDeterministically() {
    let maximum = ActivitySourceCollectionPolicy.maximumItemsPerSource
    let items = (0 ... maximum).map {
        collectionBoundItem(
            sourceID: "alpha",
            index: $0,
            updatedAt: TimeInterval($0)
        )
    }

    let snapshot = ActivitySourceSnapshot.bounded(
        items: items,
        status: .available
    )

    #expect(snapshot.items.count == maximum)
    #expect(snapshot.isTruncated)
    #expect(snapshot.items.first?.id == "alpha-actions:\(maximum)")
    #expect(snapshot.items.last?.id == "alpha-actions:1")
}

@Test
func activityAggregatorAcceptsMaximumSourceCount() async throws {
    let maximum = ActivitySourceCollectionPolicy.maximumSources
    let sources: [any ActivitySource] = (0 ..< maximum).map { index in
        ClosureActivitySource(
            id: ActivitySourceID(
                rawValue: String(format: "source%02d", index)
            )
        ) {
            ActivitySourceSnapshot(
                items: [],
                status: .available
            )
        }
    }

    let aggregate = try await ActivitySourceAggregator(
        sources: sources
    ).load()

    #expect(aggregate.sources.count == maximum)
    #expect(!aggregate.isTruncated)
}

@Test
func activityAggregatorRejectsSourceCountAboveLimit() async {
    let maximum = ActivitySourceCollectionPolicy.maximumSources
    let sources: [any ActivitySource] = (0 ... maximum).map { index in
        ClosureActivitySource(
            id: ActivitySourceID(
                rawValue: String(format: "source%02d", index)
            )
        ) {
            ActivitySourceSnapshot(
                items: [],
                status: .available
            )
        }
    }

    await #expect(
        throws: ActivitySourceAggregationError.tooManySources
    ) {
        try await ActivitySourceAggregator(
            sources: sources
        ).load()
    }
}

@Test
func activityAggregatorAcceptsPerSourceItemLimitExactly() async throws {
    let maximum = ActivitySourceCollectionPolicy.maximumItemsPerSource
    let alpha = collectionBoundSource(
        id: "alpha",
        itemCount: maximum
    )
    let beta = collectionBoundSource(
        id: "beta",
        itemCount: maximum
    )

    let aggregate = try await ActivitySourceAggregator(
        sources: [alpha, beta]
    ).load()

    #expect(
        aggregate.items.count
            == ActivitySourceCollectionPolicy.maximumAggregateItems
    )
    #expect(!aggregate.isTruncated)
}

@Test
func activityAggregatorRejectsUnboundedSourceAboveItemLimit() async {
    let maximum = ActivitySourceCollectionPolicy.maximumItemsPerSource
    let source = collectionBoundSource(
        id: "alpha",
        itemCount: maximum + 1
    )

    await #expect(
        throws: ActivitySourceAggregationError
            .sourceItemLimitExceeded(sourceID: "alpha")
    ) {
        try await ActivitySourceAggregator(
            sources: [source]
        ).load()
    }
}

@Test
func activityAggregatorBoundsAggregateAndReportsTruncation() async throws {
    let maximum = ActivitySourceCollectionPolicy.maximumItemsPerSource
    let sources: [any ActivitySource] = [
        collectionBoundSource(
            id: "alpha",
            itemCount: maximum,
            startingTimestamp: 10_000
        ),
        collectionBoundSource(
            id: "beta",
            itemCount: maximum,
            startingTimestamp: 20_000
        ),
        collectionBoundSource(
            id: "gamma",
            itemCount: 1,
            startingTimestamp: 30_000
        ),
    ]

    let aggregate = try await ActivitySourceAggregator(
        sources: sources
    ).load()

    #expect(
        aggregate.items.count
            == ActivitySourceCollectionPolicy.maximumAggregateItems
    )
    #expect(aggregate.isTruncated)
    #expect(aggregate.items.first?.id == "gamma-actions:0")
}

@Test
func activityAggregatorPropagatesSourceTruncationMetadata() async throws {
    let maximum = ActivitySourceCollectionPolicy.maximumItemsPerSource
    let source = ClosureActivitySource(id: "alpha") {
        ActivitySourceSnapshot.bounded(
            items: (0 ... maximum).map {
                collectionBoundItem(
                    sourceID: "alpha",
                    index: $0,
                    updatedAt: TimeInterval($0)
                )
            },
            status: .available
        )
    }

    let aggregate = try await ActivitySourceAggregator(
        sources: [source]
    ).load()

    #expect(aggregate.items.count == maximum)
    #expect(aggregate.sources.count == 1)
    #expect(aggregate.sources[0].isTruncated)
    #expect(aggregate.isTruncated)
}

@Test
func activityCollectionLimitKeepsCancellationAheadOfSourceCount() async {
    let maximum = ActivitySourceCollectionPolicy.maximumSources
    let sources: [any ActivitySource] = (0 ... maximum).map { index in
        ClosureActivitySource(
            id: ActivitySourceID(
                rawValue: String(format: "source%02d", index)
            )
        ) {
            ActivitySourceSnapshot(
                items: [],
                status: .available
            )
        }
    }

    let cancelled = await Task {
        withUnsafeCurrentTask { task in
            task?.cancel()
        }

        do {
            _ = try await ActivitySourceAggregator(
                sources: sources
            ).load()
            return false
        } catch is CancellationError {
            return true
        } catch {
            return false
        }
    }.value

    #expect(cancelled)
}

private func collectionBoundSource(
    id: ActivitySourceID,
    itemCount: Int,
    startingTimestamp: TimeInterval = 0
) -> ClosureActivitySource {
    ClosureActivitySource(id: id) {
        ActivitySourceSnapshot(
            items: (0 ..< itemCount).map {
                collectionBoundItem(
                    sourceID: id,
                    index: $0,
                    updatedAt: startingTimestamp
                        + TimeInterval($0)
                )
            },
            status: .available
        )
    }
}

private func collectionBoundItem(
    sourceID: ActivitySourceID,
    index: Int,
    updatedAt: TimeInterval
) -> ActivityItem {
    ActivityItem(
        id: "\(sourceID.rawValue)-actions:\(index)",
        repository: "snow/repo",
        context: "CI",
        detail: "Activity",
        state: .success,
        updatedAt: Date(timeIntervalSince1970: updatedAt)
    )
}

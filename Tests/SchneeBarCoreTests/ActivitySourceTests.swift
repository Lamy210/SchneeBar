import Foundation
import SchneeBarCore
import Testing

@Test
func activityAggregatorCombinesSuccessfulSourcesDeterministically() async throws {
    let beta = ClosureActivitySource(id: "beta") {
        ActivitySourceSnapshot(
            items: [
                activitySourceItem(
                    id: "beta-check:2",
                    state: .success,
                    updatedAt: 100
                ),
            ],
            status: .available
        )
    }
    let alpha = ClosureActivitySource(id: "alpha") {
        ActivitySourceSnapshot(
            items: [
                activitySourceItem(
                    id: "alpha-actions:1",
                    state: .failed,
                    updatedAt: 90
                ),
            ],
            status: .available
        )
    }

    let result = try await ActivitySourceAggregator(
        sources: [beta, alpha]
    ).load()

    #expect(
        result.sources == [
            ActivitySourceStatusRecord(
                sourceID: "alpha",
                status: .available
            ),
            ActivitySourceStatusRecord(
                sourceID: "beta",
                status: .available
            ),
        ]
    )
    #expect(
        result.items.map(\.id) == [
            "alpha-actions:1",
            "beta-check:2",
        ]
    )
}

@Test
func activityAggregatorPreservesHealthySourceDuringTransientFailure() async throws {
    let healthy = ClosureActivitySource(id: "alpha") {
        ActivitySourceSnapshot(
            items: [activitySourceItem(id: "alpha-actions:1")],
            status: .available
        )
    }
    let unavailable = ClosureActivitySource(id: "beta") {
        .unavailable
    }

    let result = try await ActivitySourceAggregator(
        sources: [unavailable, healthy]
    ).load()

    #expect(result.items.map(\.id) == ["alpha-actions:1"])
    #expect(
        result.sources == [
            ActivitySourceStatusRecord(
                sourceID: "alpha",
                status: .available
            ),
            ActivitySourceStatusRecord(
                sourceID: "beta",
                status: .temporarilyUnavailable
            ),
        ]
    )
}

@Test
func activityAggregatorFailsOnlyWhenNoSourceIsUsable() async {
    let alpha = ClosureActivitySource(id: "alpha") {
        .unavailable
    }
    let beta = ClosureActivitySource(id: "beta") {
        ActivitySourceSnapshot(
            items: [],
            status: .temporarilyUnavailable
        )
    }

    await #expect(
        throws: ActivitySourceAggregationError.noUsableSources(
            [
                ActivitySourceStatusRecord(
                    sourceID: "alpha",
                    status: .temporarilyUnavailable
                ),
                ActivitySourceStatusRecord(
                    sourceID: "beta",
                    status: .temporarilyUnavailable
                ),
            ]
        )
    ) {
        try await ActivitySourceAggregator(
            sources: [beta, alpha]
        ).load()
    }
}

@Test
func activityAggregatorKeepsAuthenticationStateBesideHealthySource() async throws {
    let authenticated = ClosureActivitySource(id: "alpha") {
        ActivitySourceSnapshot(
            items: [activitySourceItem(id: "alpha-actions:1")],
            status: .available
        )
    }
    let needsAuthentication = ClosureActivitySource(id: "beta") {
        ActivitySourceSnapshot(
            items: [],
            status: .authenticationRequired
        )
    }

    let result = try await ActivitySourceAggregator(
        sources: [needsAuthentication, authenticated]
    ).load()

    #expect(result.items.map(\.id) == ["alpha-actions:1"])
    #expect(
        result.sources.last
            == ActivitySourceStatusRecord(
                sourceID: "beta",
                status: .authenticationRequired
            )
    )
}

@Test
func activityAggregatorUsesGlobalInboxOrdering() async throws {
    let alpha = ClosureActivitySource(id: "alpha") {
        ActivitySourceSnapshot(
            items: [
                activitySourceItem(
                    id: "alpha-actions:1",
                    state: .success,
                    updatedAt: 300
                ),
            ],
            status: .available
        )
    }
    let beta = ClosureActivitySource(id: "beta") {
        ActivitySourceSnapshot(
            items: [
                activitySourceItem(
                    id: "beta-check:2",
                    state: .running,
                    updatedAt: 100
                ),
            ],
            status: .available
        )
    }

    let result = try await ActivitySourceAggregator(
        sources: [alpha, beta]
    ).load()

    #expect(
        result.items.map(\.id) == [
            "beta-check:2",
            "alpha-actions:1",
        ]
    )
}

private enum ActivitySourceTestError: Error {
    case providerSpecific
}

@Test
func activityAggregatorContainsProviderSpecificFailure() async throws {
    let healthy = ClosureActivitySource(id: "alpha") {
        ActivitySourceSnapshot(
            items: [activitySourceItem(id: "alpha-actions:1")],
            status: .available
        )
    }
    let failed = ClosureActivitySource(id: "beta") {
        throw ActivitySourceTestError.providerSpecific
    }

    let result = try await ActivitySourceAggregator(
        sources: [failed, healthy]
    ).load()

    #expect(result.items.map(\.id) == ["alpha-actions:1"])
    #expect(
        result.sources.last
            == ActivitySourceStatusRecord(
                sourceID: "beta",
                status: .temporarilyUnavailable
            )
    )
}

@Test
func activityAggregatorPropagatesSourceCancellation() async {
    let source = ClosureActivitySource(id: "alpha") {
        throw CancellationError()
    }

    await #expect(throws: CancellationError.self) {
        try await ActivitySourceAggregator(
            sources: [source]
        ).load()
    }
}

@Test
func activityAggregatorPreservesParentTaskCancellationEvenIfSourceReturns() async {
    let source = ClosureActivitySource(id: "alpha") {
        try? await Task.sleep(for: .milliseconds(25))
        return ActivitySourceSnapshot(
            items: [activitySourceItem(id: "alpha-actions:1")],
            status: .available
        )
    }

    let task = Task {
        try await ActivitySourceAggregator(
            sources: [source]
        ).load()
    }
    task.cancel()

    await #expect(throws: CancellationError.self) {
        try await task.value
    }
}

@Test
func activitySourceNamespaceUsesAnUnambiguousProviderPrefix() {
    let sourceID: ActivitySourceID = "github"

    #expect(sourceID.isValidNamespace)
    #expect(sourceID.owns(itemID: "github-actions:42"))
    #expect(sourceID.owns(itemID: "github:review:7"))
    #expect(!sourceID.owns(itemID: "githubenterprise-actions:42"))
    #expect(!sourceID.owns(itemID: "github"))
    #expect(!sourceID.owns(itemID: "github-"))
    #expect(!sourceID.owns(itemID: "github:"))
}

@Test
func activitySourceNamespaceIsBoundedByUTF8Bytes() {
    let maximum = ActivitySourceID(
        rawValue: String(repeating: "a", count: 64)
    )
    let oversized = ActivitySourceID(
        rawValue: String(repeating: "a", count: 65)
    )

    #expect(maximum.isValidNamespace)
    #expect(!oversized.isValidNamespace)
}

@Test
func activityItemIdentityIsBoundedAndRejectsControlCharacters() {
    let sourceID: ActivitySourceID = "alpha"
    let maximum = "alpha-" + String(repeating: "x", count: 250)
    let oversized = "alpha-" + String(repeating: "x", count: 251)

    #expect(maximum.utf8.count == 256)
    #expect(sourceID.owns(itemID: maximum))
    #expect(oversized.utf8.count == 257)
    #expect(!sourceID.owns(itemID: oversized))
    #expect(!sourceID.owns(itemID: "alpha-actions:\n1"))
    #expect(!sourceID.owns(itemID: "alpha-actions:\u{0000}1"))
}

@Test
func currentGitHubStyleActivityIdentifiersRemainValid() {
    let sourceID: ActivitySourceID = "github"

    #expect(sourceID.owns(itemID: "github-actions:123:456"))
    #expect(sourceID.owns(itemID: "github-review:123:42"))
    #expect(sourceID.owns(itemID: "github-check:123:789"))
}

@Test(arguments: [
    ActivitySourceID(rawValue: ""),
    ActivitySourceID(rawValue: "git-hub"),
    ActivitySourceID(rawValue: "git:hub"),
    ActivitySourceID(rawValue: "GitHub"),
    ActivitySourceID(rawValue: "git hub"),
    ActivitySourceID(rawValue: "git/hub"),
])
func activityAggregatorRejectsAmbiguousSourceIdentifiers(
    sourceID: ActivitySourceID
) async {
    let source = ClosureActivitySource(id: sourceID) {
        .init(items: [], status: .available)
    }

    await #expect(
        throws: ActivitySourceAggregationError.invalidSourceID
    ) {
        try await ActivitySourceAggregator(sources: [source]).load()
    }
}

@Test(arguments: [
    "alpha",
    "alpha-",
    "alpha:",
])
func activityAggregatorRejectsEmptyProviderItemIdentityPayload(
    itemID: String
) async {
    let source = ClosureActivitySource(id: "alpha") {
        ActivitySourceSnapshot(
            items: [activitySourceItem(id: itemID)],
            status: .available
        )
    }

    await #expect(
        throws: ActivitySourceAggregationError.invalidItemNamespace(
            sourceID: "alpha"
        )
    ) {
        try await ActivitySourceAggregator(
            sources: [source]
        ).load()
    }
}

@Test
func activityAggregatorRejectsItemOutsideSourceNamespace() async {
    let source = ClosureActivitySource(id: "alpha") {
        ActivitySourceSnapshot(
            items: [activitySourceItem(id: "beta-actions:1")],
            status: .available
        )
    }

    await #expect(
        throws: ActivitySourceAggregationError.invalidItemNamespace(
            sourceID: "alpha"
        )
    ) {
        try await ActivitySourceAggregator(
            sources: [source]
        ).load()
    }
}

@Test
func activityAggregatorRejectsOversizedItemWithoutRetainingRawValue() async {
    let oversized = "alpha-" + String(repeating: "x", count: 251)
    let source = ClosureActivitySource(id: "alpha") {
        ActivitySourceSnapshot(
            items: [activitySourceItem(id: oversized)],
            status: .available
        )
    }

    await #expect(
        throws: ActivitySourceAggregationError.invalidItemNamespace(
            sourceID: "alpha"
        )
    ) {
        try await ActivitySourceAggregator(
            sources: [source]
        ).load()
    }
}

@Test
func activityAggregatorRejectsControlCharacterItemWithoutRetainingRawValue() async {
    let source = ClosureActivitySource(id: "alpha") {
        ActivitySourceSnapshot(
            items: [activitySourceItem(id: "alpha-actions:\n1")],
            status: .available
        )
    }

    await #expect(
        throws: ActivitySourceAggregationError.invalidItemNamespace(
            sourceID: "alpha"
        )
    ) {
        try await ActivitySourceAggregator(
            sources: [source]
        ).load()
    }
}

@Test
func activityAggregatorRejectsOversizedSourceWithoutRetainingRawValue() async {
    let sourceID = ActivitySourceID(
        rawValue: String(repeating: "a", count: 65)
    )
    let source = ClosureActivitySource(id: sourceID) {
        .init(items: [], status: .available)
    }

    await #expect(
        throws: ActivitySourceAggregationError.invalidSourceID
    ) {
        try await ActivitySourceAggregator(sources: [source]).load()
    }
}

@Test
func activityAggregatorRejectsDuplicateItemIdentity() async {
    let source = ClosureActivitySource(id: "alpha") {
        ActivitySourceSnapshot(
            items: [
                activitySourceItem(id: "alpha-actions:1"),
                activitySourceItem(id: "alpha-actions:1"),
            ],
            status: .available
        )
    }

    await #expect(
        throws: ActivitySourceAggregationError.duplicateItemID(
            sourceID: "alpha"
        )
    ) {
        try await ActivitySourceAggregator(
            sources: [source]
        ).load()
    }
}

@Test
func activityAggregatorRejectsDuplicateSourceIdentityBeforeLoading() async {
    let first = ClosureActivitySource(id: "alpha") {
        ActivitySourceSnapshot(
            items: [activitySourceItem(id: "alpha-actions:1")],
            status: .available
        )
    }
    let second = ClosureActivitySource(id: "alpha") {
        ActivitySourceSnapshot(
            items: [activitySourceItem(id: "alpha-check:2")],
            status: .available
        )
    }

    await #expect(
        throws: ActivitySourceAggregationError.duplicateSourceID(
            "alpha"
        )
    ) {
        try await ActivitySourceAggregator(
            sources: [first, second]
        ).load()
    }
}

private func activitySourceItem(
    id: String,
    state: ActivityState = .success,
    updatedAt: TimeInterval = 100
) -> ActivityItem {
    ActivityItem(
        id: id,
        repository: "snow/repo",
        context: "CI",
        detail: "Activity",
        state: state,
        updatedAt: Date(timeIntervalSince1970: updatedAt)
    )
}

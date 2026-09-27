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

@Test(arguments: [
    Double.nan,
    Double.infinity,
    -Double.infinity,
])
func activityAggregatorRejectsNonFiniteItemTimestamp(
    timeIntervalSinceReferenceDate: Double
) async {
    let source = ClosureActivitySource(id: "alpha") {
        ActivitySourceSnapshot(
            items: [
                ActivityItem(
                    id: "alpha-actions:1",
                    repository: "snow/repo",
                    context: "CI",
                    detail: "Activity",
                    state: .success,
                    updatedAt: Date(
                        timeIntervalSinceReferenceDate:
                            timeIntervalSinceReferenceDate
                    )
                ),
            ],
            status: .available
        )
    }

    await #expect(
        throws: ActivitySourceAggregationError.invalidItemTimestamp(
            sourceID: "alpha"
        )
    ) {
        try await ActivitySourceAggregator(
            sources: [source]
        ).load()
    }
}

@Test
func activityAggregatorKeepsNamespaceErrorAheadOfTimestampValidation() async {
    let source = ClosureActivitySource(id: "alpha") {
        ActivitySourceSnapshot(
            items: [
                ActivityItem(
                    id: "beta-actions:1",
                    repository: "snow/repo",
                    context: "CI",
                    detail: "Activity",
                    state: .success,
                    updatedAt: Date(
                        timeIntervalSinceReferenceDate: .nan
                    )
                ),
            ],
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
func activityAggregatorKeepsDuplicateErrorAheadOfTimestampValidation() async {
    let source = ClosureActivitySource(id: "alpha") {
        ActivitySourceSnapshot(
            items: [
                activitySourceItem(id: "alpha-actions:1"),
                ActivityItem(
                    id: "alpha-actions:1",
                    repository: "snow/repo",
                    context: "CI",
                    detail: "Activity",
                    state: .success,
                    updatedAt: Date(
                        timeIntervalSinceReferenceDate: .infinity
                    )
                ),
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

@Test(arguments: [
    -1_000_000_000.0,
    0.0,
    10_000_000_000.0,
])
func activityAggregatorAcceptsFiniteItemTimestamp(
    timeIntervalSinceReferenceDate: Double
) async throws {
    let timestamp = Date(
        timeIntervalSinceReferenceDate:
            timeIntervalSinceReferenceDate
    )
    let source = ClosureActivitySource(id: "alpha") {
        ActivitySourceSnapshot(
            items: [
                ActivityItem(
                    id: "alpha-actions:1",
                    repository: "snow/repo",
                    context: "CI",
                    detail: "Activity",
                    state: .success,
                    updatedAt: timestamp
                ),
            ],
            status: .available
        )
    }

    let result = try await ActivitySourceAggregator(
        sources: [source]
    ).load()

    #expect(result.items.count == 1)
    #expect(result.items.first?.updatedAt == timestamp)
}

@Test
func activityAggregatorAcceptsMissingItemTimestamp() async throws {
    let source = ClosureActivitySource(id: "alpha") {
        ActivitySourceSnapshot(
            items: [
                ActivityItem(
                    id: "alpha-actions:1",
                    repository: "snow/repo",
                    context: "CI",
                    detail: "Activity",
                    state: .success,
                    updatedAt: nil
                ),
            ],
            status: .available
        )
    }

    let result = try await ActivitySourceAggregator(
        sources: [source]
    ).load()

    #expect(result.items.count == 1)
    #expect(result.items.first?.updatedAt == nil)
}

@Test(arguments: [
    "http://example.com/activity",
    "file:///tmp/activity",
    "mailto:dev@example.com",
    "schneebar://example.com/activity",
    "/relative/path",
    "https:///missing-host",
    "https://user@example.com/activity",
    "https://user:password@example.com/activity",
])
func activityAggregatorRejectsUnsafeDestinationURL(
    rawValue: String
) async throws {
    let destinationURL = try #require(URL(string: rawValue))
    let source = ClosureActivitySource(id: "alpha") {
        ActivitySourceSnapshot(
            items: [
                ActivityItem(
                    id: "alpha-actions:1",
                    repository: "snow/repo",
                    context: "CI",
                    detail: "Activity",
                    state: .success,
                    destinationURL: destinationURL,
                    updatedAt: Date(timeIntervalSince1970: 100)
                ),
            ],
            status: .available
        )
    }

    await #expect(
        throws: ActivitySourceAggregationError.invalidDestinationURL(
            sourceID: "alpha"
        )
    ) {
        try await ActivitySourceAggregator(
            sources: [source]
        ).load()
    }
}

@Test(arguments: [
    "https://github.com/snow/repo/actions/runs/1",
    "https://company.ghe.com/acme/repo/pull/2?tab=checks#summary",
    "https://github.internal.example:8443/acme/repo/actions/runs/3",
])
func activityAggregatorAcceptsHTTPSDestinationURL(
    rawValue: String
) async throws {
    let destinationURL = try #require(URL(string: rawValue))
    let source = ClosureActivitySource(id: "alpha") {
        ActivitySourceSnapshot(
            items: [
                ActivityItem(
                    id: "alpha-actions:1",
                    repository: "snow/repo",
                    context: "CI",
                    detail: "Activity",
                    state: .success,
                    destinationURL: destinationURL,
                    updatedAt: Date(timeIntervalSince1970: 100)
                ),
            ],
            status: .available
        )
    }

    let result = try await ActivitySourceAggregator(
        sources: [source]
    ).load()

    #expect(result.items.first?.destinationURL == destinationURL)
}

@Test
func activityAggregatorAcceptsMissingDestinationURL() async throws {
    let source = ClosureActivitySource(id: "alpha") {
        ActivitySourceSnapshot(
            items: [activitySourceItem(id: "alpha-actions:1")],
            status: .available
        )
    }

    let result = try await ActivitySourceAggregator(
        sources: [source]
    ).load()

    #expect(result.items.first?.destinationURL == nil)
}

@Test
func activityAggregatorKeepsNamespaceErrorAheadOfDestinationValidation() async throws {
    let destinationURL = try #require(
        URL(string: "file:///tmp/activity")
    )
    let source = ClosureActivitySource(id: "alpha") {
        ActivitySourceSnapshot(
            items: [
                ActivityItem(
                    id: "beta-actions:1",
                    repository: "snow/repo",
                    context: "CI",
                    detail: "Activity",
                    state: .success,
                    destinationURL: destinationURL
                ),
            ],
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
func activityAggregatorKeepsDuplicateErrorAheadOfDestinationValidation() async throws {
    let destinationURL = try #require(
        URL(string: "file:///tmp/activity")
    )
    let source = ClosureActivitySource(id: "alpha") {
        ActivitySourceSnapshot(
            items: [
                activitySourceItem(id: "alpha-actions:1"),
                ActivityItem(
                    id: "alpha-actions:1",
                    repository: "snow/repo",
                    context: "CI",
                    detail: "Activity",
                    state: .success,
                    destinationURL: destinationURL
                ),
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
func activityAggregatorKeepsTimestampErrorAheadOfDestinationValidation() async throws {
    let destinationURL = try #require(
        URL(string: "file:///tmp/activity")
    )
    let source = ClosureActivitySource(id: "alpha") {
        ActivitySourceSnapshot(
            items: [
                ActivityItem(
                    id: "alpha-actions:1",
                    repository: "snow/repo",
                    context: "CI",
                    detail: "Activity",
                    state: .success,
                    destinationURL: destinationURL,
                    updatedAt: Date(
                        timeIntervalSinceReferenceDate: .nan
                    )
                ),
            ],
            status: .available
        )
    }

    await #expect(
        throws: ActivitySourceAggregationError.invalidItemTimestamp(
            sourceID: "alpha"
        )
    ) {
        try await ActivitySourceAggregator(
            sources: [source]
        ).load()
    }
}

@Test
func activityAggregatorCancellationWinsBeforeDestinationValidation() async throws {
    let destinationURL = try #require(
        URL(string: "file:///tmp/activity")
    )
    let source = ClosureActivitySource(id: "alpha") {
        withUnsafeCurrentTask { task in
            task?.cancel()
        }
        return ActivitySourceSnapshot(
            items: [
                ActivityItem(
                    id: "alpha-actions:1",
                    repository: "snow/repo",
                    context: "CI",
                    detail: "Activity",
                    state: .success,
                    destinationURL: destinationURL
                ),
            ],
            status: .available
        )
    }

    await #expect(throws: CancellationError.self) {
        try await ActivitySourceAggregator(
            sources: [source]
        ).load()
    }
}

private enum ActivitySourceTestError: Error {
    case providerSpecific
}

private final class SequencedIdentityActivitySource:
    ActivitySource,
    @unchecked Sendable
{
    private let firstID: ActivitySourceID
    private let laterID: ActivitySourceID
    private(set) var idReadCount = 0

    var id: ActivitySourceID {
        idReadCount += 1
        return idReadCount == 1 ? firstID : laterID
    }

    init(
        firstID: ActivitySourceID,
        laterID: ActivitySourceID
    ) {
        self.firstID = firstID
        self.laterID = laterID
    }

    func snapshot() async throws -> ActivitySourceSnapshot {
        ActivitySourceSnapshot(
            items: [activitySourceItem(id: "alpha-actions:1")],
            status: .available
        )
    }
}

@Test
func activityAggregatorCapturesSourceIdentityExactlyOnce() async throws {
    let source = SequencedIdentityActivitySource(
        firstID: "alpha",
        laterID: "beta"
    )

    let aggregator = ActivitySourceAggregator(
        sources: [source]
    )
    let first = try await aggregator.load()
    let second = try await aggregator.load()

    #expect(source.idReadCount == 1)
    for result in [first, second] {
        #expect(
            result.sources == [
                ActivitySourceStatusRecord(
                    sourceID: "alpha",
                    status: .available
                ),
            ]
        )
        #expect(result.items.map(\.id) == ["alpha-actions:1"])
    }
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

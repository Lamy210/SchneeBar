import Foundation
import SchneeBarCore
import Testing

@Test
func activityPresentationPolicyAcceptsRepresentativeCurrentContent() {
    #expect(
        ActivityPresentationTextPolicy.allows(
            "snow-labs/frost",
            role: .repository
        )
    )
    #expect(
        ActivityPresentationTextPolicy.allows(
            "feature/release-2026.09 · CI",
            role: .title
        )
    )
    #expect(
        ActivityPresentationTextPolicy.allows(
            "Review requested · Harden wake recovery",
            role: .detail
        )
    )
}

@Test
func activityPresentationPolicyAcceptsExactThreeByteUnicodeLimits() {
    #expect(
        ActivityPresentationTextPolicy.allows(
            String(repeating: "雪", count: 512),
            role: .repository
        )
    )
    #expect(
        ActivityPresentationTextPolicy.allows(
            String(repeating: "雪", count: 1_024),
            role: .title
        )
    )
    #expect(
        ActivityPresentationTextPolicy.allows(
            String(repeating: "雪", count: 2_048),
            role: .detail
        )
    )
}

@Test
func activityPresentationPolicyRejectsCharacterLimitPlusOne() {
    #expect(
        !ActivityPresentationTextPolicy.allows(
            String(repeating: "a", count: 513),
            role: .repository
        )
    )
    #expect(
        !ActivityPresentationTextPolicy.allows(
            String(repeating: "a", count: 1_025),
            role: .title
        )
    )
    #expect(
        !ActivityPresentationTextPolicy.allows(
            String(repeating: "a", count: 2_049),
            role: .detail
        )
    )
}

@Test
func activityPresentationPolicyRejectsUTF8LimitSeparately() {
    let repository = String(repeating: "😀", count: 385)
    let title = String(repeating: "😀", count: 769)
    let detail = String(repeating: "😀", count: 1_537)

    #expect(repository.count <= 512)
    #expect(repository.utf8.count > 1_536)
    #expect(!ActivityPresentationTextPolicy.allows(repository, role: .repository))

    #expect(title.count <= 1_024)
    #expect(title.utf8.count > 3_072)
    #expect(!ActivityPresentationTextPolicy.allows(title, role: .title))

    #expect(detail.count <= 2_048)
    #expect(detail.utf8.count > 6_144)
    #expect(!ActivityPresentationTextPolicy.allows(detail, role: .detail))
}

@Test(arguments: [
    "",
    "   ",
    "\n",
    "safe\u{0000}unsafe",
])
func activityPresentationPolicyRejectsBlankOrControlContent(
    value: String
) {
    #expect(
        !ActivityPresentationTextPolicy.allows(
            value,
            role: .detail
        )
    )
}

@Test
func activityPresentationPolicyAllowsMissingOptionalContentOnly() {
    #expect(
        ActivityPresentationTextPolicy.allowsOptional(
            nil,
            role: .detail
        )
    )
    #expect(
        !ActivityPresentationTextPolicy.allowsOptional(
            " ",
            role: .detail
        )
    )
}

@Test
func activityAggregatorRejectsPresentationWithoutRetainingRawContent() async {
    let source = ClosureActivitySource(id: "alpha") {
        ActivitySourceSnapshot(
            items: [
                ActivityItem(
                    id: "alpha-actions:1",
                    repository: "snow/repo",
                    context: "CI",
                    detail: "unsafe\nprovider-content",
                    state: .success,
                    updatedAt: Date(timeIntervalSince1970: 100)
                ),
            ],
            status: .available
        )
    }

    await #expect(
        throws: ActivitySourceAggregationError.invalidItemPresentation(
            sourceID: "alpha"
        )
    ) {
        try await ActivitySourceAggregator(
            sources: [source]
        ).load()
    }
}

@Test
func activityAggregatorKeepsDestinationErrorAheadOfPresentationValidation() async throws {
    let destinationURL = try #require(
        URL(string: "file:///tmp/activity")
    )
    let source = ClosureActivitySource(id: "alpha") {
        ActivitySourceSnapshot(
            items: [
                ActivityItem(
                    id: "alpha-actions:1",
                    repository: "",
                    context: "",
                    detail: "",
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

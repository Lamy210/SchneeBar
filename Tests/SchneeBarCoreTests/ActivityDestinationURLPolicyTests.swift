import Foundation
import SchneeBarCore
import Testing

@Test(arguments: [
    "https://github.com/snow/repo/actions/runs/1",
    "https://company.ghe.com/acme/repo/pull/2?tab=checks#summary",
    "https://github.internal.example:8443/acme/repo/actions/runs/3",
])
func destinationPolicyAllowsTrustedHTTPS(
    rawValue: String
) throws {
    let url = try #require(URL(string: rawValue))

    #expect(ActivityDestinationURLPolicy.allows(url))
}

@Test(arguments: [
    "http://example.com/activity",
    "file:///tmp/activity",
    "mailto:dev@example.com",
    "custom://example.com/activity",
    "/relative/path",
    "https:///missing-host",
    "https://user@example.com/activity",
    "https://user:password@example.com/activity",
])
func destinationPolicyRejectsUnsafeURL(
    rawValue: String
) throws {
    let url = try #require(URL(string: rawValue))

    #expect(!ActivityDestinationURLPolicy.allows(url))
}

@Test
func destinationPolicyAllowsMissingURL() {
    #expect(ActivityDestinationURLPolicy.allows(nil))
}

@Test
func destinationPolicyValidatesNestedDetailRows() throws {
    let safeURL = try #require(
        URL(string: "https://github.com/snow/repo/actions/runs/1")
    )
    let unsafeURL = try #require(
        URL(string: "file:///tmp/job")
    )
    let child = ActivityDetailRow(
        id: "child",
        title: "child",
        state: .failed,
        destinationURL: unsafeURL
    )
    let parent = ActivityDetailRow(
        id: "parent",
        title: "parent",
        state: .failed,
        destinationURL: safeURL,
        children: [child]
    )
    let detail = ActivityDetailSnapshot(
        id: "activity",
        repository: "snow/repo",
        title: "CI",
        summary: "1 job",
        state: .failed,
        destinationURL: safeURL,
        rows: [parent]
    )

    #expect(!ActivityDestinationURLPolicy.allows(detail))
}

@Test
func destinationPolicyValidatesDeliveryTimelineDestinations() throws {
    let safeURL = try #require(
        URL(string: "https://github.com/snow/repo/actions/runs/1")
    )
    let unsafeURL = try #require(
        URL(string: "http://example.com/deployment")
    )
    let timeline = DeliveryTimelineSnapshot(
        status: .correlated,
        confidence: .exact,
        events: [
            DeliveryTimelineEvent(
                id: "run",
                kind: .execution,
                title: "Run",
                state: .success,
                destinationURL: safeURL
            ),
            DeliveryTimelineEvent(
                id: "deploy",
                kind: .deployment,
                title: "Deploy",
                state: .success,
                destinationURL: unsafeURL
            ),
        ]
    )
    let detail = ActivityDetailSnapshot(
        id: "activity",
        repository: "snow/repo",
        title: "CI",
        summary: "Delivery",
        state: .success,
        destinationURL: safeURL,
        deliveryTimeline: timeline,
        rows: []
    )

    #expect(!ActivityDestinationURLPolicy.allows(detail))
}

@Test
func destinationPolicyValidatesDeliveryHistoryDestinations() throws {
    let safeURL = try #require(
        URL(string: "https://github.com/snow/repo/actions/runs/1")
    )
    let unsafeURL = try #require(
        URL(string: "custom://example.com/run")
    )
    let history = DeliveryHistorySnapshot(
        repository: "snow/repo",
        entries: [
            DeliveryHistoryEntry(
                id: "safe",
                title: "Safe",
                state: .success,
                destinationURL: safeURL,
                occurredAt: Date(timeIntervalSince1970: 100)
            ),
            DeliveryHistoryEntry(
                id: "unsafe",
                title: "Unsafe",
                state: .failed,
                destinationURL: unsafeURL,
                occurredAt: Date(timeIntervalSince1970: 90)
            ),
        ]
    )

    #expect(!ActivityDestinationURLPolicy.allows(history))
}

@Test
func destinationPolicyAcceptsSafeDetailAndHistory() throws {
    let url = try #require(
        URL(string: "https://github.internal.example:8443/snow/repo")
    )
    let detail = ActivityDetailSnapshot(
        id: "activity",
        repository: "snow/repo",
        title: "CI",
        summary: "Safe",
        state: .success,
        destinationURL: url,
        deliveryTimeline: DeliveryTimelineSnapshot(
            status: .correlated,
            confidence: .exact,
            events: [
                DeliveryTimelineEvent(
                    id: "run",
                    kind: .execution,
                    title: "Run",
                    state: .success,
                    destinationURL: url
                ),
            ]
        ),
        rows: [
            ActivityDetailRow(
                id: "job",
                title: "Job",
                state: .success,
                destinationURL: url
            ),
        ]
    )
    let history = DeliveryHistorySnapshot(
        repository: "snow/repo",
        entries: [
            DeliveryHistoryEntry(
                id: "run",
                title: "Run",
                state: .success,
                destinationURL: url,
                occurredAt: Date(timeIntervalSince1970: 100)
            ),
        ]
    )

    #expect(ActivityDestinationURLPolicy.allows(detail))
    #expect(ActivityDestinationURLPolicy.allows(history))
}

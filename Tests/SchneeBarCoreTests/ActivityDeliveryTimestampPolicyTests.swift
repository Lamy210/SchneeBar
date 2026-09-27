import Foundation
import SchneeBarCore
import Testing

@Test(arguments: [
    Double.nan,
    Double.infinity,
    -Double.infinity,
])
func deliveryTimestampPolicyRejectsNonFiniteTimelineTimestamp(
    interval: Double
) {
    let detail = timestampDetail(
        occurredAt: Date(
            timeIntervalSinceReferenceDate: interval
        )
    )

    #expect(!ActivityDeliveryTimestampPolicy.allows(detail))
}

@Test
func deliveryTimestampPolicyAllowsMissingTimelineTimestamp() {
    #expect(
        ActivityDeliveryTimestampPolicy.allows(
            timestampDetail(occurredAt: nil)
        )
    )
}

@Test(arguments: [
    -1_000_000_000.0,
    0.0,
    1_000_000_000.0,
])
func deliveryTimestampPolicyAllowsFiniteTimelineTimestamp(
    interval: Double
) {
    let detail = timestampDetail(
        occurredAt: Date(
            timeIntervalSinceReferenceDate: interval
        )
    )

    #expect(ActivityDeliveryTimestampPolicy.allows(detail))
}

@Test(arguments: [
    Double.nan,
    Double.infinity,
    -Double.infinity,
])
func deliveryTimestampPolicyRejectsNonFiniteHistoryTimestamp(
    interval: Double
) {
    let history = DeliveryHistorySnapshot(
        repository: "snow/app",
        entries: [
            DeliveryHistoryEntry(
                id: "run",
                title: "Run",
                state: .failed,
                occurredAt: Date(
                    timeIntervalSinceReferenceDate: interval
                )
            ),
        ]
    )

    #expect(!ActivityDeliveryTimestampPolicy.allows(history))
}

@Test(arguments: [
    -1_000_000_000.0,
    0.0,
    1_000_000_000.0,
])
func deliveryTimestampPolicyAllowsFiniteHistoryTimestamp(
    interval: Double
) {
    let history = DeliveryHistorySnapshot(
        repository: "snow/app",
        entries: [
            DeliveryHistoryEntry(
                id: "run",
                title: "Run",
                state: .success,
                occurredAt: Date(
                    timeIntervalSinceReferenceDate: interval
                )
            ),
        ]
    )

    #expect(ActivityDeliveryTimestampPolicy.allows(history))
}

private func timestampDetail(
    occurredAt: Date?
) -> ActivityDetailSnapshot {
    ActivityDetailSnapshot(
        id: "github-actions:1:700",
        repository: "snow/app",
        title: "CI",
        summary: "Delivery",
        state: .success,
        deliveryTimeline: DeliveryTimelineSnapshot(
            status: .correlated,
            confidence: .exact,
            events: [
                DeliveryTimelineEvent(
                    id: "run",
                    kind: .execution,
                    title: "Run",
                    state: .success,
                    occurredAt: occurredAt
                ),
            ]
        ),
        rows: []
    )
}

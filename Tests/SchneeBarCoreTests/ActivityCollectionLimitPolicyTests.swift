import Foundation
import SchneeBarCore
import Testing

@Test
func collectionPolicyAcceptsExactDetailNodeLimit() {
    let children = (0 ..< 1_023).map { index in
        collectionRow(id: "child-\(index)")
    }
    let detail = collectionDetail(
        rows: [
            ActivityDetailRow(
                id: "parent",
                title: "Parent",
                state: .success,
                children: children
            ),
        ]
    )

    #expect(ActivityCollectionLimitPolicy.allows(detail))
}

@Test
func collectionPolicyRejectsDetailNodeLimitPlusOne() {
    let children = (0 ..< 1_024).map { index in
        collectionRow(id: "child-\(index)")
    }
    let detail = collectionDetail(
        rows: [
            ActivityDetailRow(
                id: "parent",
                title: "Parent",
                state: .success,
                children: children
            ),
        ]
    )

    #expect(!ActivityCollectionLimitPolicy.allows(detail))
}

@Test
func collectionPolicyRejectsDeepDetailLimitPlusOneIteratively() {
    var row = collectionRow(id: "leaf")
    for depth in 0 ..< 1_024 {
        row = ActivityDetailRow(
            id: "parent-\(depth)",
            title: "Parent",
            state: .success,
            children: [row]
        )
    }

    #expect(
        !ActivityCollectionLimitPolicy.allows(
            collectionDetail(rows: [row])
        )
    )
}

@Test
func collectionPolicyAcceptsExactTimelineLimits() {
    let events = (0 ..< 32).map { index in
        DeliveryTimelineEvent(
            id: "event-\(index)",
            kind: .deployment,
            title: "Deployment",
            state: .success
        )
    }
    let evidence = (0 ..< 32).map { index in
        DeliveryTimelineEvidenceItem(
            id: "evidence-\(index)",
            title: "Evidence",
            state: .confirmed
        )
    }
    let detail = collectionDetail(
        timeline: DeliveryTimelineSnapshot(
            status: .correlated,
            confidence: .exact,
            events: events,
            evidence: evidence
        )
    )

    #expect(ActivityCollectionLimitPolicy.allows(detail))
}

@Test
func collectionPolicyRejectsTimelineEventLimitPlusOne() {
    let events = (0 ..< 33).map { index in
        DeliveryTimelineEvent(
            id: "event-\(index)",
            kind: .deployment,
            title: "Deployment",
            state: .success
        )
    }
    let detail = collectionDetail(
        timeline: DeliveryTimelineSnapshot(
            status: .correlated,
            confidence: .exact,
            events: events
        )
    )

    #expect(!ActivityCollectionLimitPolicy.allows(detail))
}

@Test
func collectionPolicyRejectsTimelineEvidenceLimitPlusOne() {
    let evidence = (0 ..< 33).map { index in
        DeliveryTimelineEvidenceItem(
            id: "evidence-\(index)",
            title: "Evidence",
            state: .confirmed
        )
    }
    let detail = collectionDetail(
        timeline: DeliveryTimelineSnapshot(
            status: .evidenceUnavailable,
            confidence: .unknown,
            events: [],
            evidence: evidence
        )
    )

    #expect(!ActivityCollectionLimitPolicy.allows(detail))
}

@Test
func collectionPolicyAcceptsExactHistoryLimit() {
    let history = DeliveryHistorySnapshot(
        repository: "snow/app",
        entries: (0 ..< 200).map(collectionHistoryEntry)
    )

    #expect(ActivityCollectionLimitPolicy.allows(history))
}

@Test
func collectionPolicyRejectsHistoryLimitPlusOne() {
    let history = DeliveryHistorySnapshot(
        repository: "snow/app",
        entries: (0 ..< 201).map(collectionHistoryEntry)
    )

    #expect(!ActivityCollectionLimitPolicy.allows(history))
}

private func collectionDetail(
    timeline: DeliveryTimelineSnapshot? = nil,
    rows: [ActivityDetailRow] = []
) -> ActivityDetailSnapshot {
    ActivityDetailSnapshot(
        id: "github-actions:1:700",
        repository: "snow/app",
        title: "CI",
        summary: "Jobs",
        state: .success,
        deliveryTimeline: timeline,
        rows: rows
    )
}

private func collectionRow(
    id: String
) -> ActivityDetailRow {
    ActivityDetailRow(
        id: id,
        title: "Job",
        state: .success
    )
}

private func collectionHistoryEntry(
    _ index: Int
) -> DeliveryHistoryEntry {
    DeliveryHistoryEntry(
        id: "run-\(index)",
        title: "Run",
        state: .success,
        occurredAt: Date(timeIntervalSince1970: Double(index))
    )
}

import Foundation
import SchneeBarCore
import Testing

@Test
func activityPresentationPolicyAcceptsSafeDetailTreeAndTimeline() {
    let detail = ActivityDetailSnapshot(
        id: "activity",
        repository: "snow/repo",
        title: "CI",
        summary: "2 jobs",
        state: .success,
        deliveryTimeline: DeliveryTimelineSnapshot(
            status: .correlated,
            confidence: .exact,
            events: [
                DeliveryTimelineEvent(
                    id: "run",
                    kind: .execution,
                    title: "Workflow run",
                    detail: "Succeeded",
                    state: .success
                ),
            ],
            evidence: [
                DeliveryTimelineEvidenceItem(
                    id: "sha",
                    title: "Commit",
                    detail: "Exact SHA match",
                    state: .confirmed
                ),
            ]
        ),
        rows: [
            ActivityDetailRow(
                id: "group",
                title: "macOS",
                detail: "2 variants",
                state: .success,
                children: [
                    ActivityDetailRow(
                        id: "job-1",
                        title: "macOS 15",
                        detail: "Succeeded",
                        state: .success
                    ),
                ]
            ),
        ]
    )

    #expect(ActivityPresentationTextPolicy.allows(detail))
}

@Test
func activityPresentationPolicyRejectsUnsafeNestedRowContent() {
    var row = ActivityDetailRow(
        id: "leaf",
        title: "unsafe\nleaf",
        state: .failed
    )
    for depth in 0 ..< 512 {
        row = ActivityDetailRow(
            id: "parent-\(depth)",
            title: "Parent",
            state: .failed,
            children: [row]
        )
    }

    let detail = ActivityDetailSnapshot(
        id: "activity",
        repository: "snow/repo",
        title: "CI",
        summary: "Nested jobs",
        state: .failed,
        rows: [row]
    )

    #expect(!ActivityPresentationTextPolicy.allows(detail))
}

@Test
func activityPresentationPolicyRejectsUnsafeTimelineEventContent() {
    let detail = ActivityDetailSnapshot(
        id: "activity",
        repository: "snow/repo",
        title: "CI",
        summary: "Delivery",
        state: .failed,
        deliveryTimeline: DeliveryTimelineSnapshot(
            status: .correlated,
            confidence: .exact,
            events: [
                DeliveryTimelineEvent(
                    id: "deployment",
                    kind: .deployment,
                    title: " ",
                    state: .failed
                ),
            ]
        ),
        rows: []
    )

    #expect(!ActivityPresentationTextPolicy.allows(detail))
}

@Test
func activityPresentationPolicyRejectsUnsafeTimelineEvidenceContent() {
    let detail = ActivityDetailSnapshot(
        id: "activity",
        repository: "snow/repo",
        title: "CI",
        summary: "Delivery",
        state: .failed,
        deliveryTimeline: DeliveryTimelineSnapshot(
            status: .evidenceUnavailable,
            confidence: .unknown,
            events: [],
            evidence: [
                DeliveryTimelineEvidenceItem(
                    id: "evidence",
                    title: "Evidence",
                    detail: "unsafe\u{0000}detail",
                    state: .unavailable
                ),
            ]
        ),
        rows: []
    )

    #expect(!ActivityPresentationTextPolicy.allows(detail))
}

@Test
func activityPresentationPolicyRejectsUnsafeHistoryContent() {
    let history = DeliveryHistorySnapshot(
        repository: "snow/repo",
        entries: [
            DeliveryHistoryEntry(
                id: "run",
                title: "Run",
                detail: "unsafe\ncontent",
                state: .failed,
                occurredAt: Date(timeIntervalSince1970: 100)
            ),
        ]
    )

    #expect(!ActivityPresentationTextPolicy.allows(history))
}

@Test
func activityPresentationPolicyAcceptsExactUnicodeDetailBudgets() {
    let detail = ActivityDetailSnapshot(
        id: "activity",
        repository: String(repeating: "雪", count: 512),
        title: String(repeating: "雪", count: 1_024),
        summary: String(repeating: "雪", count: 2_048),
        state: .success,
        deliveryTimeline: DeliveryTimelineSnapshot(
            status: .correlated,
            confidence: .exact,
            events: [
                DeliveryTimelineEvent(
                    id: "run",
                    kind: .execution,
                    title: String(repeating: "雪", count: 1_024),
                    detail: String(repeating: "雪", count: 2_048),
                    state: .success
                ),
            ],
            evidence: [
                DeliveryTimelineEvidenceItem(
                    id: "evidence",
                    title: String(repeating: "雪", count: 1_024),
                    detail: String(repeating: "雪", count: 2_048),
                    state: .confirmed
                ),
            ]
        ),
        rows: [
            ActivityDetailRow(
                id: "job",
                title: String(repeating: "雪", count: 1_024),
                detail: String(repeating: "雪", count: 2_048),
                state: .success
            ),
        ]
    )
    let history = DeliveryHistorySnapshot(
        repository: String(repeating: "雪", count: 512),
        entries: [
            DeliveryHistoryEntry(
                id: "run",
                title: String(repeating: "雪", count: 1_024),
                detail: String(repeating: "雪", count: 2_048),
                state: .success,
                occurredAt: Date(timeIntervalSince1970: 100)
            ),
        ]
    )

    #expect(ActivityPresentationTextPolicy.allows(detail))
    #expect(ActivityPresentationTextPolicy.allows(history))
}

@Test
func activityPresentationPolicyRejectsDetailUTF8OverflowIndependently() {
    let byteHeavyTitle = String(repeating: "😀", count: 769)
    let byteHeavyDetail = String(repeating: "😀", count: 1_537)

    #expect(byteHeavyTitle.count <= 1_024)
    #expect(byteHeavyTitle.utf8.count > 3_072)
    #expect(byteHeavyDetail.count <= 2_048)
    #expect(byteHeavyDetail.utf8.count > 6_144)

    let detail = ActivityDetailSnapshot(
        id: "activity",
        repository: "snow/repo",
        title: "CI",
        summary: "Summary",
        state: .failed,
        rows: [
            ActivityDetailRow(
                id: "job",
                title: byteHeavyTitle,
                detail: byteHeavyDetail,
                state: .failed
            ),
        ]
    )

    #expect(!ActivityPresentationTextPolicy.allows(detail))
}
